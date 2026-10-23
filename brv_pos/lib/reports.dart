import 'dart:convert';
import 'db.dart';
import 'kra.dart';
import 'receipt.dart';
import 'session.dart';
import 'ui.dart' show money, qtyText;

/// Totals for a period, from KRA-signed sales and credit notes only.
/// Credit notes are subtracted, so every figure is net.
class ReportData {
  final String from; // yyyy-MM-dd
  final String to;
  int salesCount = 0, creditCount = 0, failedCount = 0, copies = 0;
  double salesTotal = 0, creditTotal = 0, discount = 0, vat = 0;
  int? firstInv, lastInv;
  final tax = <String, List<double>>{}; // band -> [taxable excl. VAT, VAT, total incl.]
  final payments = <String, List<double>>{}; // code -> [count, amount]
  final plu = <Map<String, dynamic>>[]; // item_cd, name, qty, amount
  final cashiers = <Map<String, dynamic>>[]; // name, count, amount
  ReportData(this.from, this.to);

  double get net => r2(salesTotal - creditTotal);

  Map<String, dynamic> toJson() => {
        'from': from, 'to': to, 'salesCount': salesCount, 'creditCount': creditCount, 'failedCount': failedCount,
        'copies': copies, 'salesTotal': salesTotal, 'creditTotal': creditTotal, 'discount': discount, 'vat': vat,
        'firstInv': firstInv, 'lastInv': lastInv, 'tax': tax, 'payments': payments, 'plu': plu, 'cashiers': cashiers,
      };

  static ReportData fromJson(Map<String, dynamic> j) {
    final d = ReportData('${j['from']}', '${j['to']}')
      ..salesCount = j['salesCount'] as int? ?? 0
      ..creditCount = j['creditCount'] as int? ?? 0
      ..failedCount = j['failedCount'] as int? ?? 0
      ..copies = j['copies'] as int? ?? 0
      ..salesTotal = (j['salesTotal'] as num?)?.toDouble() ?? 0
      ..creditTotal = (j['creditTotal'] as num?)?.toDouble() ?? 0
      ..discount = (j['discount'] as num?)?.toDouble() ?? 0
      ..vat = (j['vat'] as num?)?.toDouble() ?? 0
      ..firstInv = j['firstInv'] as int?
      ..lastInv = j['lastInv'] as int?;
    (j['tax'] as Map? ?? {}).forEach((k, v) => d.tax['$k'] = [for (final x in v as List) (x as num).toDouble()]);
    (j['payments'] as Map? ?? {}).forEach((k, v) => d.payments['$k'] = [for (final x in v as List) (x as num).toDouble()]);
    for (final e in (j['plu'] as List? ?? [])) {
      d.plu.add(Map<String, dynamic>.from(e as Map));
    }
    for (final e in (j['cashiers'] as List? ?? [])) {
      d.cashiers.add(Map<String, dynamic>.from(e as Map));
    }
    return d;
  }
}

class Reports {
  static String ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static Future<ReportData> build(String from, String to) async {
    final db = await Db.get();
    final d = ReportData(from, to);
    const signed = "s.status = 'signed' AND s.day BETWEEN ? AND ?";
    final args = [from, to];
    double n(Object? v) => (v as num?)?.toDouble() ?? 0;

    for (final r in await db.rawQuery(
        'SELECT s.kind, COUNT(*) c, SUM(s.tot_amt) t, SUM(s.tot_tax) v, SUM(s.copies) cp, MIN(s.invc_no) mn, MAX(s.invc_no) mx '
        'FROM sales s WHERE $signed GROUP BY s.kind',
        args)) {
      final credit = r['kind'] == 'R';
      if (credit) {
        d.creditCount = r['c'] as int;
        d.creditTotal = r2(n(r['t']));
        d.vat = r2(d.vat - n(r['v']));
      } else {
        d.salesCount = r['c'] as int;
        d.salesTotal = r2(n(r['t']));
        d.vat = r2(d.vat + n(r['v']));
      }
      d.copies += (r['cp'] as int?) ?? 0;
      final mn = r['mn'] as int?, mx = r['mx'] as int?;
      if (mn != null && (d.firstInv == null || mn < d.firstInv!)) d.firstInv = mn;
      if (mx != null && (d.lastInv == null || mx > d.lastInv!)) d.lastInv = mx;
    }
    d.failedCount = (await db.rawQuery("SELECT COUNT(*) c FROM sales s WHERE s.status = 'failed' AND s.day BETWEEN ? AND ?", args))
            .first['c'] as int? ??
        0;

    // Tax bands (from the lines, so taxable is always excl. VAT)
    for (final t in ['A', 'B', 'C', 'D', 'E']) {
      d.tax[t] = [0, 0, 0];
    }
    for (final r in await db.rawQuery(
        "SELECT l.tax, SUM(CASE WHEN s.kind = 'R' THEN -l.taxbl ELSE l.taxbl END) tb, "
        "SUM(CASE WHEN s.kind = 'R' THEN -l.tax_amt ELSE l.tax_amt END) v, "
        "SUM(CASE WHEN s.kind = 'R' THEN -l.tot ELSE l.tot END) t, "
        "SUM(CASE WHEN s.kind = 'R' THEN -l.dc_amt ELSE l.dc_amt END) dc "
        'FROM sale_lines l JOIN sales s ON s.id = l.sale_id WHERE $signed GROUP BY l.tax',
        args)) {
      d.tax['${r['tax']}'] = [r2(n(r['tb'])), r2(n(r['v'])), r2(n(r['t']))];
      d.discount = r2(d.discount + n(r['dc']));
    }

    for (final r in await db.rawQuery(
        "SELECT s.pmt_ty_cd p, SUM(CASE WHEN s.kind = 'R' THEN 0 ELSE 1 END) c, "
        "SUM(CASE WHEN s.kind = 'R' THEN -s.tot_amt ELSE s.tot_amt END) t "
        'FROM sales s WHERE $signed GROUP BY s.pmt_ty_cd ORDER BY s.pmt_ty_cd',
        args)) {
      d.payments['${r['p']}'] = [n(r['c']), r2(n(r['t']))];
    }

    for (final r in await db.rawQuery(
        "SELECT l.item_cd, MAX(l.name) name, SUM(CASE WHEN s.kind = 'R' THEN -l.qty ELSE l.qty END) q, "
        "SUM(CASE WHEN s.kind = 'R' THEN -l.tot ELSE l.tot END) t "
        'FROM sale_lines l JOIN sales s ON s.id = l.sale_id WHERE $signed GROUP BY l.item_cd ORDER BY t DESC',
        args)) {
      d.plu.add({'item_cd': r['item_cd'], 'name': r['name'], 'qty': r2(n(r['q'])), 'amount': r2(n(r['t']))});
    }

    for (final r in await db.rawQuery(
        "SELECT COALESCE(NULLIF(s.cashier, ''), '-') name, SUM(CASE WHEN s.kind = 'R' THEN 0 ELSE 1 END) c, "
        "SUM(CASE WHEN s.kind = 'R' THEN -s.tot_amt ELSE s.tot_amt END) t "
        'FROM sales s WHERE $signed GROUP BY 1 ORDER BY t DESC',
        args)) {
      d.cashiers.add({'name': r['name'], 'count': (r['c'] as num?)?.toInt() ?? 0, 'amount': r2(n(r['t']))});
    }
    return d;
  }

  /// The Z report of a closed day, if any.
  static Future<Map<String, dynamic>?> z(String day) async {
    final db = await Db.get();
    final r = await db.query('z_reports', where: 'day = ?', whereArgs: [day], limit: 1);
    return r.isEmpty ? null : Map<String, dynamic>.from(r.first);
  }

  /// Close the day: freeze its totals under the next Z number.
  static Future<Map<String, dynamic>> closeDay(String day) async {
    final existing = await z(day);
    if (existing != null) return existing;
    final data = await build(day, day);
    final db = await Db.get();
    late Map<String, dynamic> row;
    await db.transaction((tx) async {
      final mx = (await tx.rawQuery('SELECT MAX(z_no) m FROM z_reports')).first['m'] as int? ?? 0;
      row = {
        'z_no': mx + 1,
        'day': day,
        'created_at': DateTime.now().toIso8601String(),
        'closed_by': Session.i.name,
        'data': jsonEncode(data.toJson()),
      };
      row['id'] = await tx.insert('z_reports', row);
    });
    return row;
  }

  static String _dmy(String ymd) {
    final p = ymd.split('-');
    return p.length == 3 ? '${p[2]}/${p[1]}/${p[0]}' : ymd;
  }

  static String _now() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}/${two(t.month)}/${t.year} ${two(t.hour)}:${two(t.minute)}';
  }

  /// Printable lines for a report.
  static List<PLine> lines(ReportData d, {required String title, String? subtitle, bool items = true, String? footer}) {
    String m(double v) => money(v, symbol: false);
    return [
      PLine.center(title, size: 26, bold: true),
      if (subtitle != null) PLine.center(subtitle, size: 19, bold: true),
      PLine.center(d.from == d.to ? 'Date ${_dmy(d.from)}' : '${_dmy(d.from)} to ${_dmy(d.to)}', size: 18),
      PLine.center('Printed ${_now()}${Session.i.name.isEmpty ? '' : ' by ${Session.i.name}'}', size: 16),
      const PLine.dash(),
      PLine.row('Sales (${d.salesCount})', m(d.salesTotal), size: 19),
      PLine.row('Credit notes (${d.creditCount})', '-${m(d.creditTotal)}', size: 19),
      PLine.row('NET SALES', m(d.net), size: 23, bold: true),
      PLine.row('Discounts given', m(d.discount), size: 18),
      if (d.firstInv != null) PLine.row('Invoices', '${d.firstInv} - ${d.lastInv}', size: 18),
      PLine.row('Copies printed', '${d.copies}', size: 18),
      if (d.failedCount > 0) PLine.row('Not signed (void)', '${d.failedCount}', size: 18),
      const PLine.dash(),
      const PLine.center('TAX SUMMARY', size: 20, bold: true),
      for (final t in ['A', 'B', 'C', 'D', 'E']) ...[
        if (d.tax[t]![2] != 0 || Kra.rate(t) > 0) ...[
          PLine.left(Kra.find(Kra.taxTypes, t)!.name, size: 18, bold: true),
          PLine.row('  Taxable amount', m(d.tax[t]![0]), size: 18),
          PLine.row('  VAT', m(d.tax[t]![1]), size: 18),
          PLine.row('  Total', m(d.tax[t]![2]), size: 18),
        ],
      ],
      PLine.row('TOTAL VAT', m(d.vat), size: 21, bold: true),
      const PLine.dash(),
      const PLine.center('PAYMENTS', size: 20, bold: true),
      if (d.payments.isEmpty) const PLine.center('None', size: 18),
      for (final e in d.payments.entries)
        PLine.row('${Kra.paymentName(e.key)} (${e.value[0].toInt()})', m(e.value[1]), size: 18),
      const PLine.dash(),
      const PLine.center('CASHIERS', size: 20, bold: true),
      for (final c in d.cashiers) PLine.row('${c['name']} (${c['count']})', m((c['amount'] as num).toDouble()), size: 18),
      if (items && d.plu.isNotEmpty) ...[
        const PLine.dash(),
        const PLine.center('ITEMS SOLD (PLU)', size: 20, bold: true),
        for (final p in d.plu) PLine.row('${p['name']} x${qtyText((p['qty'] as num).toDouble())}', m((p['amount'] as num).toDouble()), size: 18),
      ],
      const PLine.dash(),
      if (footer != null) PLine.center(footer, size: 19, bold: true),
    ];
  }
}
