import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'db.dart';
import 'fmt.dart';
import 'ledger.dart';
import 'session.dart';
import 'settings.dart';
import 'stock.dart';

class CartLine {
  final int productId;
  final String name;
  final double taxRate;
  final double cost;
  final bool track;
  double price; // unit price incl. VAT
  double qty;
  double discount; // amount off this line
  CartLine({required this.productId, required this.name, required this.price, required this.taxRate,
      required this.cost, required this.track, this.qty = 1, this.discount = 0});

  double get gross => r2(price * qty);
  double get total => r2(gross - discount);
  double get tax => Settings.i.vatRegistered && taxRate > 0 ? r2(total * taxRate / (100 + taxRate)) : 0.0;
}

/// The sale being built on the Sell screen.
class Cart extends ChangeNotifier {
  Cart._();
  static final Cart i = Cart._();

  final List<CartLine> lines = [];
  int? customerId;
  String customerName = '';

  double get total => lines.fold<double>(0, (a, l) => a + l.total);
  double get tax => lines.fold<double>(0, (a, l) => a + l.tax);
  double get discount => lines.fold<double>(0, (a, l) => a + l.discount);
  double get count => lines.fold<double>(0, (a, l) => a + l.qty);
  bool get isEmpty => lines.isEmpty;

  void add(Map<String, Object?> p, {double q = 1}) {
    final id = n(p['id']);
    final i = lines.indexWhere((l) => l.productId == id && l.discount == 0);
    if (i >= 0) {
      lines[i].qty += q;
    } else {
      lines.add(CartLine(
          productId: id, name: s(p['name']), price: d(p['price']), taxRate: d(p['tax_rate']), cost: d(p['cost']),
          track: n(p['track']) == 1, qty: q));
    }
    notifyListeners();
  }

  void setQty(CartLine l, double q) {
    if (q <= 0) {
      lines.remove(l);
    } else {
      l.qty = q;
    }
    notifyListeners();
  }

  void changed() => notifyListeners();

  void clear() {
    lines.clear();
    customerId = null;
    customerName = '';
    notifyListeners();
  }

  double qtyOf(int productId) => lines.where((l) => l.productId == productId).fold<double>(0, (a, l) => a + l.qty);
}

class Pay {
  final int methodId;
  final String kind; // cash | mpesa | card | credit | other
  final String name;
  double amount;
  String ref;
  Pay(this.methodId, this.kind, this.name, this.amount, {this.ref = ''});
}

class SaleError implements Exception {
  final String message;
  SaleError(this.message);
  @override
  String toString() => message;
}

class Sales {
  /// Where this user sells from: their shift's location, else the default selling location.
  static Future<int> sellingLocation() async {
    final sh = Session.i.shift;
    if (sh != null) return n(sh['location_id']);
    final def = int.tryParse(Settings.i.get('sell_location')) ?? 0;
    if (def > 0) return def;
    final r = await Db.one("SELECT id FROM locations WHERE active = 1 ORDER BY kind = 'shop' DESC, id LIMIT 1");
    return n(r?['id']);
  }

  static Future<double> customerBalance(DatabaseExecutor tx, int customerId) async {
    final a = await tx.rawQuery(
        "SELECT COALESCE(SUM(sp.amount),0) v FROM sale_payments sp JOIN sales s ON s.id = sp.sale_id "
        "JOIN pay_methods m ON m.id = sp.method_id WHERE m.kind = 'credit' AND s.customer_id = ?",
        [customerId]);
    final b = await tx.rawQuery('SELECT COALESCE(SUM(amount),0) v FROM customer_payments WHERE customer_id = ?', [customerId]);
    return d(a.first['v']) - d(b.first['v']);
  }

  /// Saves the sale: lines, payments, stock out, journal. Returns the sale id.
  static Future<int> checkout(Cart cart, List<Pay> given, {String note = ''}) async {
    final ses = Session.i;
    // work on copies: if the sale is refused, the cashier's payments stay as typed
    final pays = [for (final p in given) Pay(p.methodId, p.kind, p.name, p.amount, ref: p.ref)];
    if (cart.isEmpty) throw SaleError('The sale is empty.');
    if (Settings.i.requireShift && ses.shift == null) throw SaleError('Open your shift first (cash drawer).');
    final total = r2(cart.total);
    final paid = r2(pays.fold<double>(0, (a, p) => a + p.amount));
    if (paid + 0.004 < total) throw SaleError('Paid ${money(paid)} is less than the total ${money(total)}.');
    final credit = pays.where((p) => p.kind == 'credit').fold<double>(0, (a, p) => a + p.amount);
    if (credit > 0 && cart.customerId == null) throw SaleError('Choose the customer for a credit sale.');
    var change = r2(paid - total);
    if (change > 0) {
      final cash = pays.where((p) => p.kind == 'cash').toList();
      final cashIn = cash.fold<double>(0, (a, p) => a + p.amount);
      if (cashIn + 0.004 < change) throw SaleError('Only cash can be more than the total (change).');
      var left = change;
      for (final p in cash) {
        final take = left > p.amount ? p.amount : left;
        p.amount = r2(p.amount - take);
        left = r2(left - take);
      }
    }
    final location = await sellingLocation();
    final db = await Db.get();
    late int saleId;
    await db.transaction((tx) async {
      if (credit > 0) {
        final c = await tx.rawQuery('SELECT name, credit_limit FROM customers WHERE id = ?', [cart.customerId]);
        final limit = c.isEmpty ? 0.0 : d(c.first['credit_limit']);
        if (limit > 0) {
          final bal = await customerBalance(tx, cart.customerId!);
          if (bal + credit > limit + 0.004) {
            throw SaleError('${c.first['name']} would owe ${money(bal + credit)}, over the limit ${money(limit)}.');
          }
        }
      }
      if (Settings.i.blockNoStock && !ses.can('sell_no_stock')) {
        final need = <int, double>{};
        final names = <int, String>{};
        for (final l in cart.lines.where((l) => l.track)) {
          need[l.productId] = (need[l.productId] ?? 0) + l.qty;
          names[l.productId] = l.name;
        }
        for (final e in need.entries) {
          final have = await Stock.onHand(tx, e.key, location);
          if (have + 0.00001 < e.value) {
            throw SaleError('${names[e.key]}: only ${qty(have < 0 ? 0 : have)} in stock here, the sale has ${qty(e.value)}.');
          }
        }
      }
      final number = await Db.nextNumber(tx, 'sale', 'S-', 6);
      final now = DateTime.now();
      final tax = r2(cart.tax);
      final cost = r2(cart.lines.where((l) => l.track).fold<double>(0, (a, l) => a + l.cost * l.qty));
      saleId = await tx.insert('sales', {
        'number': number, 'date': now.toIso8601String(), 'day': dayKey(now), 'user_id': ses.userId,
        'shift_id': ses.shift == null ? null : n(ses.shift!['id']), 'location_id': location,
        'customer_id': cart.customerId, 'net': r2(total - tax), 'tax': tax, 'discount': r2(cart.discount),
        'total': total, 'cost': cost, 'paid': paid, 'change': change, 'kind': 'sale', 'state': 'done', 'note': note,
      });
      for (final l in cart.lines) {
        await tx.insert('sale_lines', {
          'sale_id': saleId, 'product_id': l.productId, 'name': l.name, 'qty': l.qty, 'price': l.price,
          'discount': l.discount, 'tax_rate': l.taxRate, 'tax': l.tax, 'total': l.total, 'cost': l.cost,
        });
        if (l.track) {
          await Stock.move(tx, productId: l.productId, from: location, to: 0, qty: l.qty, cost: l.cost,
              kind: 'sale', ref: number, userId: ses.userId);
        }
      }
      final lines = <(int, double, double, String)>[];
      for (final p in pays) {
        if (p.amount.abs() < 0.004) continue;
        await tx.insert('sale_payments', {'sale_id': saleId, 'method_id': p.methodId, 'amount': p.amount, 'ref': p.ref});
        final m = await tx.rawQuery('SELECT account_id FROM pay_methods WHERE id = ?', [p.methodId]);
        lines.add((n(m.first['account_id']), p.amount, 0.0, p.kind == 'credit' ? cart.customerName : ''));
      }
      lines.add((await Db.account(tx, 'sales'), 0.0, r2(total - tax), ''));
      if (tax > 0) lines.add((await Db.account(tx, 'vat'), 0.0, tax, ''));
      if (cost > 0) {
        lines.add((await Db.account(tx, 'cogs'), cost, 0.0, ''));
        lines.add((await Db.account(tx, 'inventory'), 0.0, cost, ''));
      }
      await Ledger.post(tx, ref: number, memo: 'Sale $number', kind: 'sale', userId: ses.userId, lines: lines);
    });
    return saleId;
  }

  /// Full refund of a sale: stock back, money back by the same methods, reversed journal.
  static Future<int> refund(int saleId, {String reason = ''}) async {
    final ses = Session.i;
    final db = await Db.get();
    late int refundId;
    await db.transaction((tx) async {
      final sl = await tx.rawQuery('SELECT * FROM sales WHERE id = ?', [saleId]);
      if (sl.isEmpty) throw SaleError('Sale not found.');
      final sale = sl.first;
      if (s(sale['kind']) != 'sale' || s(sale['state']) == 'refunded') throw SaleError('This sale is already refunded.');
      final number = await Db.nextNumber(tx, 'refund', 'R-', 6);
      final now = DateTime.now();
      final location = n(sale['location_id']);
      refundId = await tx.insert('sales', {
        'number': number, 'date': now.toIso8601String(), 'day': dayKey(now), 'user_id': ses.userId,
        'shift_id': ses.shift == null ? null : n(ses.shift!['id']), 'location_id': location,
        'customer_id': sale['customer_id'], 'net': -d(sale['net']), 'tax': -d(sale['tax']),
        'discount': -d(sale['discount']), 'total': -d(sale['total']), 'cost': -d(sale['cost']),
        'paid': -(d(sale['paid']) - d(sale['change'])), 'change': 0, 'kind': 'refund', 'ref_sale_id': saleId,
        'state': 'done', 'note': reason,
      });
      for (final l in await tx.rawQuery('SELECT * FROM sale_lines WHERE sale_id = ?', [saleId])) {
        await tx.insert('sale_lines', {
          'sale_id': refundId, 'product_id': l['product_id'], 'name': l['name'], 'qty': -d(l['qty']), 'price': l['price'],
          'discount': -d(l['discount']), 'tax_rate': l['tax_rate'], 'tax': -d(l['tax']), 'total': -d(l['total']), 'cost': l['cost'],
        });
        final p = await tx.rawQuery('SELECT track FROM products WHERE id = ?', [l['product_id']]);
        if (p.isNotEmpty && n(p.first['track']) == 1) {
          await Stock.move(tx, productId: n(l['product_id']), from: 0, to: location, qty: d(l['qty']), cost: d(l['cost']),
              kind: 'refund', ref: number, userId: ses.userId, note: 'Refund of ${sale['number']}');
        }
      }
      final lines = <(int, double, double, String)>[];
      for (final p in await tx.rawQuery(
          'SELECT sp.*, m.account_id FROM sale_payments sp JOIN pay_methods m ON m.id = sp.method_id WHERE sp.sale_id = ?', [saleId])) {
        await tx.insert('sale_payments', {'sale_id': refundId, 'method_id': p['method_id'], 'amount': -d(p['amount']), 'ref': 'refund'});
        lines.add((n(p['account_id']), 0.0, d(p['amount']), ''));
      }
      final tax = d(sale['tax']), net = d(sale['net']), cost = d(sale['cost']);
      lines.add((await Db.account(tx, 'sales'), net, 0.0, ''));
      if (tax.abs() > 0) lines.add((await Db.account(tx, 'vat'), tax, 0.0, ''));
      if (cost.abs() > 0) {
        lines.add((await Db.account(tx, 'inventory'), cost, 0.0, ''));
        lines.add((await Db.account(tx, 'cogs'), 0.0, cost, ''));
      }
      await Ledger.post(tx, ref: number, memo: 'Refund of ${sale['number']}${reason.isEmpty ? '' : ': $reason'}',
          kind: 'refund', userId: ses.userId, lines: lines);
      await tx.update('sales', {'state': 'refunded'}, where: 'id = ?', whereArgs: [saleId]);
      await Db.audit(tx, ses.userId, 'refund', '${sale['number']} ${money(d(sale['total']))} $reason');
    });
    return refundId;
  }

  static Future<Map<String, Object?>?> sale(int id) => Db.one(
      'SELECT s.*, u.name AS cashier, c.name AS customer, l.name AS location FROM sales s '
      'LEFT JOIN users u ON u.id = s.user_id LEFT JOIN customers c ON c.id = s.customer_id '
      'LEFT JOIN locations l ON l.id = s.location_id WHERE s.id = ?',
      [id]);

  static Future<List<Map<String, Object?>>> lines(int id) => Db.q('SELECT * FROM sale_lines WHERE sale_id = ? ORDER BY id', [id]);

  static Future<List<Map<String, Object?>>> payments(int id) => Db.q(
      'SELECT sp.*, m.name, m.kind FROM sale_payments sp JOIN pay_methods m ON m.id = sp.method_id WHERE sp.sale_id = ?', [id]);
}

/// Shifts: the cash drawer of one person from opening to closing.
class Shifts {
  static Future<void> open({required int locationId, required double openingCash}) async {
    final ses = Session.i;
    final db = await Db.get();
    await db.transaction((tx) async {
      final open = await tx.rawQuery("SELECT id FROM shifts WHERE user_id = ? AND state = 'open'", [ses.userId]);
      if (open.isNotEmpty) throw SaleError('You already have an open shift.');
      final number = await Db.nextNumber(tx, 'shift', 'SH-', 5);
      await tx.insert('shifts', {
        'number': number, 'user_id': ses.userId, 'location_id': locationId, 'opened_at': nowIso(),
        'opening_cash': openingCash, 'state': 'open',
      });
      await Db.audit(tx, ses.userId, 'shift_open', '$number float ${money(openingCash)}');
    });
    await ses.refreshShift();
  }

  /// Cash that should be in the drawer now.
  static Future<Map<String, double>> cashSummary(int shiftId) async {
    final sh = await Db.one('SELECT * FROM shifts WHERE id = ?', [shiftId]);
    final opening = d(sh?['opening_cash']);
    final sales = await Db.sum(
        "SELECT COALESCE(SUM(sp.amount),0) FROM sale_payments sp JOIN sales s ON s.id = sp.sale_id "
        "JOIN pay_methods m ON m.id = sp.method_id WHERE m.kind = 'cash' AND s.shift_id = ?",
        [shiftId]);
    final received = await Db.sum(
        "SELECT COALESCE(SUM(cp.amount),0) FROM customer_payments cp JOIN pay_methods m ON m.id = cp.method_id "
        "WHERE m.kind = 'cash' AND cp.shift_id = ?",
        [shiftId]);
    final expenses = await Db.sum(
        "SELECT COALESCE(SUM(e.amount),0) FROM expenses e JOIN pay_methods m ON m.id = e.method_id "
        "WHERE m.kind = 'cash' AND e.shift_id = ?",
        [shiftId]);
    final paidOut = await Db.sum(
        "SELECT COALESCE(SUM(p.amount),0) FROM supplier_payments p JOIN pay_methods m ON m.id = p.method_id "
        "WHERE m.kind = 'cash' AND p.shift_id = ?",
        [shiftId]);
    return {
      'opening': opening, 'sales': sales, 'received': received, 'expenses': expenses, 'paid_out': paidOut,
      'expected': r2(opening + sales + received - expenses - paidOut),
    };
  }

  static Future<Map<String, Object?>> close(int shiftId, double counted, {String note = ''}) async {
    final ses = Session.i;
    final sum = await cashSummary(shiftId);
    final expected = sum['expected']!;
    final diff = r2(counted - expected);
    final db = await Db.get();
    await db.transaction((tx) async {
      final sh = await tx.rawQuery('SELECT * FROM shifts WHERE id = ?', [shiftId]);
      if (sh.isEmpty || s(sh.first['state']) != 'open') throw SaleError('This shift is not open.');
      await tx.update('shifts', {
        'closed_at': nowIso(), 'expected_cash': expected, 'counted_cash': counted, 'diff': diff, 'state': 'closed', 'note': note,
      }, where: 'id = ?', whereArgs: [shiftId]);
      if (diff.abs() >= 0.01) {
        final cash = await Db.account(tx, 'cash');
        final other = await Db.account(tx, diff < 0 ? 'cash_short' : 'cash_over');
        final a = diff.abs();
        await Ledger.post(tx, ref: s(sh.first['number']), memo: 'Shift ${sh.first['number']} cash ${diff < 0 ? 'short' : 'over'}',
            kind: 'shift', userId: ses.userId,
            lines: diff < 0 ? [(other, a, 0.0, ''), (cash, 0.0, a, '')] : [(cash, a, 0.0, ''), (other, 0.0, a, '')]);
      }
      await Db.audit(tx, ses.userId, 'shift_close', '${sh.first['number']} expected ${money(expected)} counted ${money(counted)}');
    });
    await ses.refreshShift();
    return (await Db.one('SELECT * FROM shifts WHERE id = ?', [shiftId]))!;
  }

  /// Totals of a shift for the Z report.
  static Future<Map<String, Object>> report(int shiftId) async {
    final sh = await Db.one(
        'SELECT sh.*, u.name AS user, l.name AS location FROM shifts sh LEFT JOIN users u ON u.id = sh.user_id '
        'LEFT JOIN locations l ON l.id = sh.location_id WHERE sh.id = ?',
        [shiftId]);
    final sales = await Db.one(
        "SELECT COUNT(*) c, COALESCE(SUM(total),0) t, COALESCE(SUM(tax),0) x, COALESCE(SUM(discount),0) dsc "
        "FROM sales WHERE shift_id = ? AND kind = 'sale'",
        [shiftId]);
    final refunds = await Db.one(
        "SELECT COUNT(*) c, COALESCE(SUM(total),0) t FROM sales WHERE shift_id = ? AND kind = 'refund'", [shiftId]);
    final methods = await Db.q(
        'SELECT m.name, SUM(sp.amount) a FROM sale_payments sp JOIN sales s ON s.id = sp.sale_id '
        'JOIN pay_methods m ON m.id = sp.method_id WHERE s.shift_id = ? GROUP BY m.id ORDER BY a DESC',
        [shiftId]);
    return {
      'shift': sh ?? <String, Object?>{},
      'sales': sales ?? <String, Object?>{},
      'refunds': refunds ?? <String, Object?>{},
      'methods': methods,
      'cash': await cashSummary(shiftId),
    };
  }
}
