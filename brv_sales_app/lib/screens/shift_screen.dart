import 'package:flutter/material.dart';
import '../backup.dart';
import '../bus.dart';
import '../db.dart';
import '../fmt.dart';
import '../perms.dart';
import '../receipt.dart';
import '../sales.dart';
import '../session.dart';
import '../ui.dart';

/// Open the cash drawer with a float, close it by counting the cash, print the Z report.
class ShiftScreen extends StatefulWidget {
  const ShiftScreen({super.key});
  @override
  State<ShiftScreen> createState() => _ShiftScreenState();
}

class _ShiftScreenState extends State<ShiftScreen> {
  Map<String, double>? _cash;
  List<Map<String, Object?>> _locations = [];
  int _loc = 0;
  final _float = TextEditingController(text: '0');
  final _counted = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await Db.q('SELECT * FROM locations WHERE active = 1 ORDER BY kind = \'shop\' DESC, name');
    final sh = Session.i.shift;
    Map<String, double>? c;
    if (sh != null) c = await Shifts.cashSummary(n(sh['id']));
    final def = await Sales.sellingLocation();
    if (mounted) {
      setState(() {
        _locations = l;
        _loc = _loc == 0 ? def : _loc;
        _cash = c;
      });
    }
  }

  Future<void> _open() async {
    final f = numIn(_float.text) ?? -1;
    if (f < 0) {
      toast(context, 'Enter the cash in the drawer (float).');
      return;
    }
    setState(() => _busy = true);
    try {
      await Shifts.open(locationId: _loc, openingCash: f);
      changed();
      if (mounted) toast(context, 'Shift open. You can sell now.');
      await _load();
    } on SaleError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    final sh = Session.i.shift!;
    final c = numIn(_counted.text);
    if (c == null || c < 0) {
      toast(context, 'Count the cash in the drawer and enter it.');
      return;
    }
    final expected = _cash?['expected'] ?? 0;
    final diff = r2(c - expected);
    if (!await confirm(context, 'Close shift ${sh['number']}?',
        'Expected ${money(expected)}\nCounted ${money(c)}\n${diff == 0 ? 'No difference.' : 'Difference ${diff > 0 ? '+' : ''}${money(diff)} (${diff < 0 ? 'short' : 'over'})'}',
        ok: 'Close shift')) {
      return;
    }
    setState(() => _busy = true);
    try {
      final closed = await Shifts.close(n(sh['id']), c);
      changed();
      Backup.auto();
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ZReport(shiftId: n(closed['id']))));
    } on SaleError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sh = Session.i.shift;
    final cash = _cash;
    return Scaffold(
      appBar: AppBar(title: const Text('Shift'), actions: [
        IconButton(
          tooltip: 'Past shifts',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShiftHistory())),
          icon: const Icon(Icons.history),
        ),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        if (sh == null) ...[
          Container(
            padding: const EdgeInsets.all(18),
            decoration: box(color: C.ink, border: false),
            child: const Text('Open your shift: choose where you sell from and count the cash already in the drawer.',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          const Label('Selling from'),
          DropdownButtonFormField<int>(
            value: _locations.any((l) => n(l['id']) == _loc) ? _loc : null,
            items: [for (final l in _locations) DropdownMenuItem(value: n(l['id']), child: Text(s(l['name'])))],
            onChanged: (v) => setState(() => _loc = v ?? _loc),
          ),
          const Label('Cash in the drawer now (float)'),
          TextField(controller: _float, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(prefixText: 'KSh ')),
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : _open, child: const Text('Open shift')),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(18),
            decoration: box(color: C.ink, border: false),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Shift ${s(sh['number'])}', style: h(20, color: Colors.white)),
              Text('Open since ${dateText(sh['opened_at'])}', style: const TextStyle(color: Color(0xFFCBD5E1))),
              const SizedBox(height: 12),
              const Text('Cash expected in the drawer', style: TextStyle(color: Color(0xFFCBD5E1))),
              Text(money(cash?['expected'] ?? 0), style: h(30, color: C.gold)),
            ]),
          ),
          const SizedBox(height: 12),
          if (cash != null)
            Container(
              decoration: box(),
              child: Column(children: [
                KV('Opening float', money(cash['opening']!)),
                KV('Cash sales (less refunds)', money(cash['sales']!)),
                KV('Cash received from customers', money(cash['received']!)),
                KV('Cash expenses paid', '-${money(cash['expenses']!)}'),
                KV('Cash paid to suppliers', '-${money(cash['paid_out']!)}'),
                KV('Expected', money(cash['expected']!), bold: true),
              ]),
            ),
          const Label('Close the shift: count the cash'),
          TextField(controller: _counted, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Cash counted', prefixText: 'KSh ')),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _close,
            style: FilledButton.styleFrom(backgroundColor: C.red),
            child: const Text('Close shift and print Z report'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ZReport(shiftId: n(sh['id'])))),
            child: const Text('X report (so far, shift stays open)'),
          ),
        ],
      ]),
    );
  }
}

class ZReport extends StatefulWidget {
  final int shiftId;
  const ZReport({super.key, required this.shiftId});
  @override
  State<ZReport> createState() => _ZReportState();
}

class _ZReportState extends State<ZReport> {
  Map<String, Object>? _r;

  @override
  void initState() {
    super.initState();
    Shifts.report(widget.shiftId).then((r) {
      if (mounted) setState(() => _r = r);
    });
  }

  List<PLine> _lines(Map<String, Object> r) {
    final sh = r['shift'] as Map<String, Object?>;
    final sales = r['sales'] as Map<String, Object?>;
    final ref = r['refunds'] as Map<String, Object?>;
    final cash = r['cash'] as Map<String, double>;
    final closed = s(sh['state']) == 'closed';
    return [
      PLine.center(closed ? 'Z REPORT' : 'X REPORT (shift open)', size: 23, bold: true),
      const PLine.dash(),
      PLine.row('Shift', s(sh['number'])),
      PLine.row('Cashier', s(sh['user'])),
      PLine.row('Location', s(sh['location'])),
      PLine.row('Opened', dateText(sh['opened_at'])),
      if (closed) PLine.row('Closed', dateText(sh['closed_at'])),
      const PLine.dash(),
      PLine.row('Sales', '${n(sales['c'])}'),
      PLine.row('Sales total', money(d(sales['t']), symbol: false), bold: true),
      if (d(sales['dsc']) != 0) PLine.row('Discounts', money(d(sales['dsc']), symbol: false)),
      if (d(sales['x']) != 0) PLine.row('VAT in sales', money(d(sales['x']), symbol: false)),
      if (n(ref['c']) > 0) PLine.row('Refunds (${n(ref['c'])})', money(d(ref['t']), symbol: false)),
      const PLine.dash(),
      const PLine.left('Payments', bold: true),
      for (final m in (r['methods'] as List).cast<Map<String, Object?>>()) PLine.row('  ${s(m['name'])}', money(d(m['a']), symbol: false)),
      const PLine.dash(),
      const PLine.left('Cash drawer', bold: true),
      PLine.row('  Float', money(cash['opening']!, symbol: false)),
      PLine.row('  Cash sales', money(cash['sales']!, symbol: false)),
      if (cash['received']! != 0) PLine.row('  From customers', money(cash['received']!, symbol: false)),
      if (cash['expenses']! != 0) PLine.row('  Expenses', '-${money(cash['expenses']!, symbol: false)}'),
      if (cash['paid_out']! != 0) PLine.row('  To suppliers', '-${money(cash['paid_out']!, symbol: false)}'),
      PLine.row('  Expected', money(cash['expected']!, symbol: false), bold: true),
      if (closed) PLine.row('  Counted', money(d(sh['counted_cash']), symbol: false), bold: true),
      if (closed) PLine.row('  Difference', money(d(sh['diff']), symbol: false), bold: true),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return Scaffold(
      appBar: AppBar(title: const Text('Shift report'), actions: [
        if (r != null)
          IconButton(
            onPressed: () async {
              final ok = await Printer.printLines(_lines(r), 'Shift report');
              if (context.mounted) toast(context, ok ? 'Printed.' : 'Printer not found. Choose it in More > Printer.');
            },
            icon: const Icon(Icons.print_outlined),
          ),
        if (r != null)
          IconButton(onPressed: () => Printer.pdf(_lines(r), 'Shift report', share: true), icon: const Icon(Icons.share_outlined)),
      ]),
      body: r == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Container(
                decoration: box(),
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(children: [
                  for (final l in _lines(r)) lineWidget(l),
                ]),
              ),
            ]),
    );
  }
}

class ShiftHistory extends StatefulWidget {
  const ShiftHistory({super.key});
  @override
  State<ShiftHistory> createState() => _ShiftHistoryState();
}

class _ShiftHistoryState extends State<ShiftHistory> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    final all = Session.i.can(P.allSales) || Session.i.can(P.reports);
    Db.q('SELECT sh.*, u.name AS user FROM shifts sh LEFT JOIN users u ON u.id = sh.user_id '
            '${all ? '' : 'WHERE sh.user_id = ${Session.i.userId}'} ORDER BY sh.id DESC LIMIT 200')
        .then((r) {
      if (mounted) setState(() => _rows = r);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Shifts')),
        body: _rows.isEmpty
            ? const Empty(Icons.history, 'No shifts yet.')
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: _rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, k) {
                  final r = _rows[k];
                  final open = s(r['state']) == 'open';
                  final diff = d(r['diff']);
                  return Container(
                    decoration: box(),
                    child: ListTile(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ZReport(shiftId: n(r['id'])))),
                      title: Text('${s(r['number'])} · ${s(r['user'])}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${dateText(r['opened_at'])}${open ? '' : ' → ${dateText(r['closed_at'])}'}'),
                      trailing: open
                          ? const Pill('OPEN', fg: C.green, bg: C.greenLight)
                          : Text(diff == 0 ? 'OK' : money(diff), style: h(13.5, color: diff < 0 ? C.red : (diff > 0 ? C.amber : C.green))),
                    ),
                  );
                },
              ),
      );
}

/// A printout line shown on screen.
Widget lineWidget(PLine l) {
  if (l.kind == 'dash') return const Divider();
  if (l.kind == 'gap') return SizedBox(height: l.size);
  if (l.kind == 'row') return KV(l.a, l.b, bold: l.bold);
  return Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text(l.a, style: h(l.kind == 'center' ? 18 : 15)));
}
