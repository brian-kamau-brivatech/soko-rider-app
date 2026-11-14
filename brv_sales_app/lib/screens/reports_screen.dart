import 'package:flutter/material.dart';
import '../bus.dart';
import '../db.dart';
import '../fmt.dart';
import '../receipt.dart';
import '../ui.dart';
import 'accounting_screen.dart' show Period, PeriodBar;
import 'shell.dart';
import 'shift_screen.dart' show ShiftHistory, lineWidget;

/// Sales reports for a period: summary, by item, by staff, by payment, by day, VAT, stock, debtors and creditors.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final _p = Period.today();
  String _kind = 'summary';
  List<PLine> _lines = [];
  bool _loading = true;

  static const kinds = [
    ('summary', 'Summary'), ('items', 'By item'), ('staff', 'By staff'), ('payments', 'By payment'), ('days', 'By day'),
    ('categories', 'By category'), ('vat', 'VAT'), ('stock', 'Stock value'), ('debtors', 'Customers owing'), ('creditors', 'Suppliers owed'),
  ];

  @override
  void initState() {
    super.initState();
    dataSettled.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataSettled.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final a = _p.a, b = _p.b;
    final out = <PLine>[
      PLine.center(kinds.firstWhere((k) => k.$1 == _kind).$2.toUpperCase(), size: 22, bold: true),
      if (!['stock', 'debtors', 'creditors'].contains(_kind)) PLine.center(_p.label, size: 18),
      PLine.center('Printed ${dateText(nowIso())}', size: 15),
      const PLine.dash(),
    ];
    switch (_kind) {
      case 'summary': {
        final t = await Db.one(
            "SELECT COUNT(CASE WHEN kind='sale' THEN 1 END) c, COALESCE(SUM(CASE WHEN kind='sale' THEN total END),0) gross, "
            "COALESCE(SUM(CASE WHEN kind='refund' THEN total END),0) ref, COALESCE(SUM(total),0) net_sales, COALESCE(SUM(tax),0) tax, "
            "COALESCE(SUM(discount),0) disc, COALESCE(SUM(cost),0) cost, COALESCE(SUM(net),0) net FROM sales WHERE date >= ? AND date < ?",
            [a, b]);
        final c = d(t?['c']);
        out.addAll([
          PLine.row('Sales (receipts)', qty(c)),
          PLine.row('Gross sales', money(d(t?['gross']), symbol: false)),
          PLine.row('Refunds', money(d(t?['ref']), symbol: false)),
          PLine.row('Net sales', money(d(t?['net_sales']), symbol: false), bold: true),
          PLine.row('Average sale', money(c > 0 ? d(t?['gross']) / c : 0, symbol: false)),
          PLine.row('Discounts given', money(d(t?['disc']), symbol: false)),
          PLine.row('VAT in sales', money(d(t?['tax']), symbol: false)),
          PLine.row('Sales excl. VAT', money(d(t?['net']), symbol: false)),
          PLine.row('Cost of goods', money(d(t?['cost']), symbol: false)),
          PLine.row('Gross profit', money(d(t?['net']) - d(t?['cost']), symbol: false), bold: true),
        ]);
        final exp = await Db.sum('SELECT COALESCE(SUM(amount),0) FROM expenses WHERE date >= ? AND date < ?', [a, b]);
        out.addAll([
          PLine.row('Expenses', money(exp, symbol: false)),
          PLine.row('Profit after expenses', money(d(t?['net']) - d(t?['cost']) - exp, symbol: false), bold: true),
        ]);
      }
      case 'items': {
        for (final r in await Db.q(
            'SELECT l.name, SUM(l.qty) q, SUM(l.total) t, SUM(l.total - l.tax - l.cost * l.qty) gp FROM sale_lines l JOIN sales s ON s.id = l.sale_id '
            'WHERE s.date >= ? AND s.date < ? GROUP BY l.product_id ORDER BY t DESC',
            [a, b])) {
          out.add(PLine.row('${s(r['name'])} x${qty(d(r['q']))}', money(d(r['t']), symbol: false), bold: true));
          out.add(PLine.left('   profit ${money(d(r['gp']), symbol: false)}', size: 16));
        }
      }
      case 'staff': {
        for (final r in await Db.q(
            "SELECT u.name, COUNT(CASE WHEN s.kind='sale' THEN 1 END) c, SUM(s.total) t FROM sales s JOIN users u ON u.id = s.user_id "
            "WHERE s.date >= ? AND s.date < ? GROUP BY s.user_id ORDER BY t DESC",
            [a, b])) {
          out.add(PLine.row('${s(r['name'])} (${n(r['c'])})', money(d(r['t']), symbol: false)));
        }
      }
      case 'payments': {
        for (final r in await Db.q(
            'SELECT m.name, SUM(sp.amount) t, COUNT(*) c FROM sale_payments sp JOIN sales s ON s.id = sp.sale_id JOIN pay_methods m ON m.id = sp.method_id '
            'WHERE s.date >= ? AND s.date < ? GROUP BY m.id ORDER BY t DESC',
            [a, b])) {
          out.add(PLine.row('${s(r['name'])} (${n(r['c'])})', money(d(r['t']), symbol: false)));
        }
        final recv = await Db.q(
            'SELECT m.name, SUM(cp.amount) t FROM customer_payments cp JOIN pay_methods m ON m.id = cp.method_id WHERE cp.date >= ? AND cp.date < ? GROUP BY m.id',
            [a, b]);
        if (recv.isNotEmpty) {
          out.add(const PLine.dash());
          out.add(const PLine.left('Received from customers', bold: true));
          for (final r in recv) {
            out.add(PLine.row('  ${s(r['name'])}', money(d(r['t']), symbol: false)));
          }
        }
      }
      case 'days': {
        for (final r in await Db.q(
            "SELECT day, COUNT(CASE WHEN kind='sale' THEN 1 END) c, SUM(total) t FROM sales WHERE date >= ? AND date < ? GROUP BY day ORDER BY day",
            [a, b])) {
          out.add(PLine.row('${dateText(s(r['day']), time: false)} (${n(r['c'])})', money(d(r['t']), symbol: false)));
        }
      }
      case 'categories': {
        for (final r in await Db.q(
            "SELECT COALESCE(c.name, 'No category') name, SUM(l.qty) q, SUM(l.total) t FROM sale_lines l JOIN sales s ON s.id = l.sale_id "
            "LEFT JOIN products p ON p.id = l.product_id LEFT JOIN categories c ON c.id = p.category_id "
            "WHERE s.date >= ? AND s.date < ? GROUP BY c.id ORDER BY t DESC",
            [a, b])) {
          out.add(PLine.row('${s(r['name'])} x${qty(d(r['q']))}', money(d(r['t']), symbol: false)));
        }
      }
      case 'vat': {
        for (final r in await Db.q(
            'SELECT l.tax_rate rate, SUM(l.total - l.tax) taxable, SUM(l.tax) tax FROM sale_lines l JOIN sales s ON s.id = l.sale_id '
            'WHERE s.date >= ? AND s.date < ? GROUP BY l.tax_rate ORDER BY l.tax_rate DESC',
            [a, b])) {
          out.add(PLine.left('VAT ${qty(d(r['rate']))}%', bold: true));
          out.add(PLine.row('  Sales excl. VAT', money(d(r['taxable']), symbol: false)));
          out.add(PLine.row('  VAT', money(d(r['tax']), symbol: false)));
        }
        out.add(const PLine.dash());
        out.add(PLine.row('Total VAT', money(await Db.sum('SELECT COALESCE(SUM(tax),0) FROM sales WHERE date >= ? AND date < ?', [a, b]), symbol: false), bold: true));
      }
      case 'stock': {
        var total = 0.0;
        for (final l in await Db.q('SELECT * FROM locations WHERE active = 1 ORDER BY name')) {
          final v = await Db.sum('SELECT COALESCE(SUM(s.qty * p.cost),0) FROM stock s JOIN products p ON p.id = s.product_id WHERE s.location_id = ? AND s.qty > 0', [l['id']]);
          total += v;
          out.add(PLine.row(s(l['name']), money(v, symbol: false)));
        }
        out.add(PLine.row('Total at cost', money(total, symbol: false), bold: true));
        final retail = await Db.sum('SELECT COALESCE(SUM(s.qty * p.price),0) FROM stock s JOIN products p ON p.id = s.product_id WHERE s.qty > 0');
        out.add(PLine.row('At selling price', money(retail, symbol: false)));
      }
      case 'debtors': {
        var total = 0.0;
        for (final r in await Db.q(
            "SELECT c.name, (SELECT COALESCE(SUM(sp.amount),0) FROM sale_payments sp JOIN sales s ON s.id = sp.sale_id JOIN pay_methods m ON m.id = sp.method_id "
            "WHERE m.kind = 'credit' AND s.customer_id = c.id) - (SELECT COALESCE(SUM(amount),0) FROM customer_payments cp WHERE cp.customer_id = c.id) AS owes "
            "FROM customers c ORDER BY owes DESC")) {
          if (d(r['owes']).abs() < 0.005) continue;
          total += d(r['owes']);
          out.add(PLine.row(s(r['name']), money(d(r['owes']), symbol: false)));
        }
        out.add(PLine.row('Total owed to you', money(total, symbol: false), bold: true));
      }
      case 'creditors': {
        var total = 0.0;
        for (final r in await Db.q(
            "SELECT s.name, (SELECT COALESCE(SUM(total),0) FROM purchases p WHERE p.supplier_id = s.id AND p.state = 'received') - "
            "(SELECT COALESCE(SUM(amount),0) FROM supplier_payments sp WHERE sp.supplier_id = s.id) AS owing FROM suppliers s ORDER BY owing DESC")) {
          if (d(r['owing']).abs() < 0.005) continue;
          total += d(r['owing']);
          out.add(PLine.row(s(r['name']), money(d(r['owing']), symbol: false)));
        }
        out.add(PLine.row('Total you owe', money(total, symbol: false), bold: true));
      }
    }
    if (out.length <= 4) out.add(const PLine.center('Nothing in this period.', size: 17));
    if (mounted) setState(() { _lines = out; _loading = false; });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: TopBar('Reports', actions: [
          IconButton(
            tooltip: 'Print',
            onPressed: () async {
              final ok = await Printer.printLines(_lines, 'Report');
              if (context.mounted) toast(context, ok ? 'Printed.' : 'Printer not found. Choose it in More > Printer.');
            },
            icon: const Icon(Icons.print_outlined),
          ),
          IconButton(tooltip: 'Share PDF', onPressed: () => Printer.pdf(_lines, 'Report $_kind', share: true), icon: const Icon(Icons.share_outlined)),
        ]),
        body: Column(children: [
          SizedBox(
            height: 46,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (final k in kinds)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(k.$2),
                    selected: _kind == k.$1,
                    showCheckmark: false,
                    selectedColor: C.ink,
                    labelStyle: TextStyle(color: _kind == k.$1 ? Colors.white : C.text, fontWeight: FontWeight.w700),
                    onSelected: (_) { setState(() => _kind = k.$1); _load(); },
                  ),
                ),
            ]),
          ),
          if (!['stock', 'debtors', 'creditors'].contains(_kind)) PeriodBar(period: _p, onChanged: _load),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                    Container(
                      decoration: box(),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final l in _lines) lineWidget(l)]),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShiftHistory())),
                      icon: const Icon(Icons.history),
                      label: const Text('Session (Z) reports'),
                    ),
                  ]),
          ),
        ]),
      );
}
