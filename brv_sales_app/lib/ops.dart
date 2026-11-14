import 'db.dart';
import 'fmt.dart';
import 'ledger.dart';
import 'sales.dart' show SaleError;
import 'session.dart';
import 'stock.dart';

/// Purchases from suppliers: order, receive into stock, pay.
class Purchases {
  /// lines: (product id, name, qty, unit cost). Returns the purchase id.
  static Future<int> save({int? id, required int supplierId, required int locationId,
      required List<(int, String, double, double)> lines, String note = '', String supplierRef = ''}) async {
    if (lines.isEmpty) throw SaleError('Add at least one item.');
    final ses = Session.i;
    final db = await Db.get();
    late int pid;
    await db.transaction((tx) async {
      final total = r2(lines.fold<double>(0, (a, l) => a + l.$3 * l.$4));
      if (id == null) {
        final number = await Db.nextNumber(tx, 'po', 'PO-', 5);
        pid = await Db.ins(tx, 'purchases', {
          'number': number, 'date': nowIso(), 'supplier_id': supplierId, 'location_id': locationId, 'state': 'draft',
          'total': total, 'user_id': ses.userId, 'note': note, 'supplier_ref': supplierRef,
        });
      } else {
        pid = id;
        final cur = await tx.rawQuery('SELECT state FROM purchases WHERE id = ?', [id]);
        if (cur.isEmpty || s(cur.first['state']) != 'draft') throw SaleError('Only a draft order can be changed.');
        await tx.update('purchases', {'supplier_id': supplierId, 'location_id': locationId, 'total': total, 'note': note, 'supplier_ref': supplierRef},
            where: 'id = ?', whereArgs: [id]);
        await tx.delete('purchase_lines', where: 'purchase_id = ?', whereArgs: [id]);
      }
      for (final l in lines) {
        await Db.ins(tx, 'purchase_lines', {'purchase_id': pid, 'product_id': l.$1, 'name': l.$2, 'qty': l.$3, 'cost': l.$4, 'total': r2(l.$3 * l.$4)});
      }
    });
    return pid;
  }

  /// Stock in at cost, average cost updated, supplier owed (Inventory / Suppliers payable).
  static Future<void> receive(int id) async {
    final ses = Session.i;
    final db = await Db.get();
    await db.transaction((tx) async {
      final pr = await tx.rawQuery('SELECT p.*, s.name AS supplier FROM purchases p LEFT JOIN suppliers s ON s.id = p.supplier_id WHERE p.id = ?', [id]);
      if (pr.isEmpty) throw SaleError('Purchase not found.');
      final p = pr.first;
      if (s(p['state']) != 'draft') throw SaleError('This purchase is already ${p['state']}.');
      var total = 0.0;
      for (final l in await tx.rawQuery('SELECT * FROM purchase_lines WHERE purchase_id = ?', [id])) {
        final q = d(l['qty']), c = d(l['cost']);
        final prod = await tx.rawQuery('SELECT track FROM products WHERE id = ?', [l['product_id']]);
        if (prod.isNotEmpty && n(prod.first['track']) == 1) {
          await Stock.updateAverageCost(tx, n(l['product_id']), q, c);
          await Stock.move(tx, productId: n(l['product_id']), from: 0, to: n(p['location_id']), qty: q, cost: c,
              kind: 'purchase', ref: s(p['number']), userId: ses.userId);
        }
        total += q * c;
      }
      total = r2(total);
      await tx.update('purchases', {'state': 'received', 'received_at': nowIso(), 'total': total}, where: 'id = ?', whereArgs: [id]);
      await Ledger.post(tx, ref: s(p['number']), memo: 'Received from ${p['supplier'] ?? ''}', kind: 'purchase', userId: ses.userId,
          lines: [(await Db.account(tx, 'inventory'), total, 0.0, ''), (await Db.account(tx, 'ap'), 0.0, total, s(p['supplier']))]);
      await Db.audit(tx, ses.userId, 'purchase_receive', '${p['number']} ${money(total)}');
    });
  }

  static Future<void> cancel(int id) async {
    final db = await Db.get();
    final n0 = await db.update('purchases', {'state': 'cancel'}, where: "id = ? AND state = 'draft'", whereArgs: [id]);
    if (n0 == 0) throw SaleError('Only a draft order can be cancelled.');
  }

  static Future<double> supplierBalance(int supplierId) async {
    final owed = await Db.sum("SELECT COALESCE(SUM(total),0) FROM purchases WHERE supplier_id = ? AND state = 'received'", [supplierId]);
    final paid = await Db.sum('SELECT COALESCE(SUM(amount),0) FROM supplier_payments WHERE supplier_id = ?', [supplierId]);
    return r2(owed - paid);
  }

  static Future<double> paidOn(int purchaseId) =>
      Db.sum('SELECT COALESCE(SUM(amount),0) FROM supplier_payments WHERE purchase_id = ?', [purchaseId]);

  static Future<void> pay({required int supplierId, int? purchaseId, required int methodId, required double amount, String ref = ''}) async {
    if (amount <= 0) throw SaleError('Enter the amount.');
    final ses = Session.i;
    final db = await Db.get();
    await db.transaction((tx) async {
      final m = await tx.rawQuery('SELECT account_id, kind FROM pay_methods WHERE id = ?', [methodId]);
      if (m.isEmpty || s(m.first['kind']) == 'credit') throw SaleError('Choose how you paid (cash, M-Pesa, bank).');
      final sup = await tx.rawQuery('SELECT name FROM suppliers WHERE id = ?', [supplierId]);
      final name = sup.isEmpty ? '' : s(sup.first['name']);
      await Db.ins(tx, 'supplier_payments', {
        'date': nowIso(), 'supplier_id': supplierId, 'purchase_id': purchaseId, 'method_id': methodId, 'amount': amount,
        'ref': ref, 'user_id': ses.userId, 'shift_id': ses.shift == null ? null : n(ses.shift!['id']),
      });
      await Ledger.post(tx, ref: ref.isEmpty ? 'Payment' : ref, memo: 'Paid $name', kind: 'supplier_payment', userId: ses.userId,
          lines: [(await Db.account(tx, 'ap'), amount, 0.0, name), (n(m.first['account_id']), 0.0, amount, '')]);
    });
  }
}

class Customers {
  static Future<void> receive({required int customerId, required int methodId, required double amount, String ref = ''}) async {
    if (amount <= 0) throw SaleError('Enter the amount.');
    final ses = Session.i;
    final db = await Db.get();
    await db.transaction((tx) async {
      final m = await tx.rawQuery('SELECT account_id, kind FROM pay_methods WHERE id = ?', [methodId]);
      if (m.isEmpty || s(m.first['kind']) == 'credit') throw SaleError('Choose how the customer paid.');
      final c = await tx.rawQuery('SELECT name FROM customers WHERE id = ?', [customerId]);
      final name = c.isEmpty ? '' : s(c.first['name']);
      await Db.ins(tx, 'customer_payments', {
        'date': nowIso(), 'customer_id': customerId, 'method_id': methodId, 'amount': amount, 'ref': ref,
        'user_id': ses.userId, 'shift_id': ses.shift == null ? null : n(ses.shift!['id']),
      });
      await Ledger.post(tx, ref: ref.isEmpty ? 'Receipt' : ref, memo: 'Received from $name', kind: 'customer_payment', userId: ses.userId,
          lines: [(n(m.first['account_id']), amount, 0.0, ''), (await Db.account(tx, 'ar'), 0.0, amount, name)]);
    });
  }
}

/// Requisitions: a location asks another (usually the main store) for stock; approval moves it.
class Requisitions {
  static Future<int> create({required int fromLoc, required int toLoc, required List<(int, double)> lines, String note = ''}) async {
    if (fromLoc == toLoc) throw SaleError('Choose two different locations.');
    if (lines.isEmpty) throw SaleError('Add at least one item.');
    final ses = Session.i;
    final db = await Db.get();
    late int rid;
    await db.transaction((tx) async {
      final number = await Db.nextNumber(tx, 'req', 'REQ-', 5);
      rid = await Db.ins(tx, 'requisitions', {
        'number': number, 'date': nowIso(), 'from_loc': fromLoc, 'to_loc': toLoc, 'state': 'pending', 'user_id': ses.userId, 'note': note,
      });
      for (final l in lines) {
        await Db.ins(tx, 'requisition_lines', {'requisition_id': rid, 'product_id': l.$1, 'qty': l.$2});
      }
    });
    return rid;
  }

  /// Moves what the source location has (up to the amount asked). Returns items short.
  static Future<List<String>> approve(int id, {Map<int, double>? approvedQty}) async {
    final ses = Session.i;
    final db = await Db.get();
    final short = <String>[];
    await db.transaction((tx) async {
      final rq = await tx.rawQuery('SELECT * FROM requisitions WHERE id = ?', [id]);
      if (rq.isEmpty || s(rq.first['state']) != 'pending') throw SaleError('This requisition is not waiting for approval.');
      final r = rq.first;
      var moved = 0.0;
      for (final l in await tx.rawQuery(
          'SELECT rl.*, p.name, p.cost FROM requisition_lines rl JOIN products p ON p.id = rl.product_id WHERE rl.requisition_id = ?', [id])) {
        final want = approvedQty?[n(l['id'])] ?? d(l['qty']);
        final have = await Stock.onHand(tx, n(l['product_id']), n(r['from_loc']));
        final give = want <= 0 ? 0.0 : (have < want ? (have > 0 ? have : 0.0) : want);
        if (give + 0.00001 < want) short.add('${l['name']}: asked ${qty(want)}, sent ${qty(give)}');
        if (give > 0) {
          await Stock.move(tx, productId: n(l['product_id']), from: n(r['from_loc']), to: n(r['to_loc']), qty: give,
              cost: d(l['cost']), kind: 'transfer', ref: s(r['number']), userId: ses.userId);
          moved += give;
        }
        await tx.update('requisition_lines', {'qty_sent': give}, where: 'id = ?', whereArgs: [l['id']]);
      }
      if (moved <= 0) throw SaleError('The source location has none of these items. Nothing was moved.');
      await tx.update('requisitions', {'state': 'approved', 'approved_by': ses.userId, 'approved_at': nowIso()},
          where: 'id = ?', whereArgs: [id]);
      await Db.audit(tx, ses.userId, 'requisition_approve', '${r['number']}${short.isEmpty ? '' : ' short: ${short.join('; ')}'}');
    });
    return short;
  }

  static Future<void> setState(int id, String state) async {
    final db = await Db.get();
    final c = await db.update('requisitions', {'state': state, 'approved_by': Session.i.userId, 'approved_at': nowIso()},
        where: "id = ? AND state = 'pending'", whereArgs: [id]);
    if (c == 0) throw SaleError('This requisition is not waiting for approval.');
  }
}

class Expenses {
  static Future<void> record({required int accountId, required int methodId, required double amount, String note = ''}) async {
    if (amount <= 0) throw SaleError('Enter the amount.');
    final ses = Session.i;
    final db = await Db.get();
    await db.transaction((tx) async {
      final m = await tx.rawQuery('SELECT account_id, kind FROM pay_methods WHERE id = ?', [methodId]);
      if (m.isEmpty || s(m.first['kind']) == 'credit') throw SaleError('Choose how it was paid.');
      final a = await tx.rawQuery('SELECT name FROM accounts WHERE id = ?', [accountId]);
      await Db.ins(tx, 'expenses', {
        'date': nowIso(), 'account_id': accountId, 'method_id': methodId, 'amount': amount, 'note': note,
        'user_id': ses.userId, 'shift_id': ses.shift == null ? null : n(ses.shift!['id']),
      });
      await Ledger.post(tx, ref: 'Expense', memo: '${a.isEmpty ? '' : a.first['name']}${note.isEmpty ? '' : ': $note'}',
          kind: 'expense', userId: ses.userId, lines: [(accountId, amount, 0.0, ''), (n(m.first['account_id']), 0.0, amount, '')]);
    });
  }
}
