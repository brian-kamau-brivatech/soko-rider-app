import 'package:sqflite/sqflite.dart';
import 'db.dart';
import 'fmt.dart';
import 'ledger.dart';

/// Stock on hand per product and location, and every movement.
class Stock {
  static Future<double> onHand(DatabaseExecutor tx, int productId, int locationId) async {
    final r = await tx.rawQuery('SELECT qty FROM stock WHERE product_id = ? AND location_id = ?', [productId, locationId]);
    return r.isEmpty ? 0.0 : d(r.first['qty']);
  }

  static Future<double> total(DatabaseExecutor tx, int productId) async {
    final r = await tx.rawQuery('SELECT SUM(qty) q FROM stock WHERE product_id = ?', [productId]);
    return r.isEmpty ? 0.0 : d(r.first['q']);
  }

  static Future<void> _add(DatabaseExecutor tx, int productId, int locationId, double qtyDelta) async {
    final updated = await tx.rawUpdate('UPDATE stock SET qty = qty + ? WHERE product_id = ? AND location_id = ?',
        [qtyDelta, productId, locationId]);
    if (updated == 0) {
      await tx.insert('stock', {'product_id': productId, 'location_id': locationId, 'qty': qtyDelta});
    }
  }

  /// Moves [qty] of a product. from/to = 0 means outside (customer, supplier, adjustment).
  static Future<void> move(DatabaseExecutor tx,
      {required int productId, required int from, required int to, required double qty, required double cost,
      required String kind, required String ref, required int userId, String note = ''}) async {
    if (qty.abs() < 0.00001) return;
    if (from > 0) await _add(tx, productId, from, -qty);
    if (to > 0) await _add(tx, productId, to, qty);
    await Db.ins(tx, 'stock_moves', {
      'date': nowIso(), 'product_id': productId, 'from_loc': from, 'to_loc': to, 'qty': qty, 'cost': cost,
      'kind': kind, 'ref': ref, 'user_id': userId, 'note': note,
    });
  }

  /// Average cost when new stock comes in at [unitCost].
  static Future<void> updateAverageCost(DatabaseExecutor tx, int productId, double qtyIn, double unitCost) async {
    final p = await tx.rawQuery('SELECT cost FROM products WHERE id = ?', [productId]);
    if (p.isEmpty) return;
    final have = await total(tx, productId);
    final old = d(p.first['cost']);
    final base = have > 0 ? have : 0.0;
    final cost = (base + qtyIn) > 0 ? (base * old + qtyIn * unitCost) / (base + qtyIn) : unitCost;
    await tx.update('products', {'cost': (cost * 10000).roundToDouble() / 10000}, where: 'id = ?', whereArgs: [productId]);
  }

  /// Sets the counted quantity at a location (stock count / adjustment). Posts the value difference.
  /// opening = true: first stock entered (Inventory against Owner's capital, not a loss).
  static Future<double> setCounted(DatabaseExecutor tx,
      {required int productId, required int locationId, required double counted, required int userId,
      String note = '', bool opening = false, double? unitCost}) async {
    final have = await onHand(tx, productId, locationId);
    final diff = counted - have;
    if (diff.abs() < 0.00001) return 0;
    final p = await tx.rawQuery('SELECT name, cost FROM products WHERE id = ?', [productId]);
    var cost = d(p.isEmpty ? 0 : p.first['cost']);
    if (opening && unitCost != null && diff > 0) {
      await updateAverageCost(tx, productId, diff, unitCost);
      cost = unitCost;
    }
    final ref = opening ? 'Opening stock' : 'Stock count';
    await move(tx,
        productId: productId, from: diff < 0 ? locationId : 0, to: diff > 0 ? locationId : 0, qty: diff.abs(),
        cost: cost, kind: opening ? 'opening' : 'adjust', ref: ref, userId: userId, note: note);
    final value = r2(diff * cost);
    if (value.abs() >= 0.01) {
      final inv = await Db.account(tx, 'inventory');
      final other = await Db.account(tx, opening ? 'equity' : 'stock_loss');
      await Ledger.post(tx, ref: ref, memo: '${p.isEmpty ? '' : p.first['name']} ${diff > 0 ? '+' : ''}${qty(diff)}${note.isEmpty ? '' : ' ($note)'}',
          kind: 'stock', userId: userId, lines: [(inv, value, 0.0, ''), (other, 0.0, value, '')]);
    }
    return diff;
  }

  /// Products with their quantity at a location (or all locations when [locationId] is 0).
  static Future<List<Map<String, Object?>>> list({int locationId = 0, String search = '', bool onlyTracked = true}) async {
    final where = <String>['p.active = 1'];
    final args = <Object?>[];
    if (onlyTracked) where.add('p.track = 1');
    if (search.trim().isNotEmpty) {
      where.add('(p.name LIKE ? OR p.sku LIKE ? OR p.barcode = ?)');
      args.addAll(['%${search.trim()}%', '%${search.trim()}%', search.trim()]);
    }
    final qtySql = locationId > 0
        ? '(SELECT COALESCE(SUM(qty),0) FROM stock s WHERE s.product_id = p.id AND s.location_id = $locationId)'
        : '(SELECT COALESCE(SUM(qty),0) FROM stock s WHERE s.product_id = p.id)';
    return Db.q(
        'SELECT p.*, $qtySql AS on_hand, c.name AS category FROM products p LEFT JOIN categories c ON c.id = p.category_id '
        'WHERE ${where.join(' AND ')} ORDER BY p.name',
        args);
  }
}
