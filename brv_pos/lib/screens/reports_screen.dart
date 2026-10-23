import 'dart:convert';
import 'package:flutter/material.dart';
import '../backup.dart';
import '../db.dart';
import '../kra.dart';
import '../receipt.dart';
import '../reports.dart';
import '../session.dart';
import '../ui.dart';

/// Daily (X / Z), monthly and custom period reports, printable or PDF.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String _mode = 'day'; // day | month | range
  DateTime _day = DateTime.now();
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTimeRange? _range;
  ReportData? _data;
  Map<String, dynamic>? _z;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  (String, String) get _period {
    switch (_mode) {
      case 'month':
        final last = DateTime(_month.year, _month.month + 1, 0);
        return (Reports.ymd(_month), Reports.ymd(last));
      case 'range':
        final r = _range ?? DateTimeRange(start: DateTime.now().subtract(const Duration(days: 6)), end: DateTime.now());
        return (Reports.ymd(r.start), Reports.ymd(r.end));
      default:
        return (Reports.ymd(_day), Reports.ymd(_day));
    }
  }

  Future<void> _load() async {
    try {
      final (from, to) = _period;
      final d = await Reports.build(from, to);
      final z = _mode == 'day' ? await Reports.z(from) : null;
      if (mounted) {
        setState(() {
          _data = d;
          _z = z;
          _error = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  static const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

  String get _label {
    final (from, to) = _period;
    if (_mode == 'month') return '${_months[_month.month - 1]} ${_month.year}';
    if (_mode == 'day') return Reports.ymd(DateTime.now()) == from ? 'Today' : '${_day.day}/${_day.month}/${_day.year}';
    return '$from → $to';
  }

  void _step(int by) {
    setState(() {
      if (_mode == 'month') {
        _month = DateTime(_month.year, _month.month + by);
      } else {
        _day = _day.add(Duration(days: by));
      }
    });
    _load();
  }

  Future<void> _pick() async {
    if (_mode == 'range') {
      final r = await showDateRangePicker(
          context: context, firstDate: DateTime(2020), lastDate: DateTime.now(), initialDateRange: _range);
      if (r != null) {
        _range = r;
        _load();
      }
      return;
    }
    final d = await showDatePicker(
        context: context, initialDate: _mode == 'month' ? _month : _day, firstDate: DateTime(2020), lastDate: DateTime.now());
    if (d == null) return;
    setState(() {
      if (_mode == 'month') {
        _month = DateTime(d.year, d.month);
      } else {
        _day = d;
      }
    });
    _load();
  }

  Future<List<PLine>> _printLines({required bool zCopy}) async {
    final d = _data!;
    if (_mode == 'day') {
      if (_z != null) {
        final zd = ReportData.fromJson(Map<String, dynamic>.from(jsonDecode('${_z!['data']}') as Map));
        return Reports.lines(zd,
            title: 'Z REPORT', subtitle: 'No. ${_z!['z_no']}${zCopy ? ' (COPY)' : ''}', footer: 'DAY CLOSED by ${_z!['closed_by']}');
      }
      return Reports.lines(d, title: 'X REPORT', subtitle: 'Day not closed', footer: 'END OF X REPORT');
    }
    return Reports.lines(d, title: _mode == 'month' ? 'MONTHLY REPORT' : 'SALES REPORT', subtitle: _label.toUpperCase());
  }

  Future<void> _print() async {
    setState(() => _busy = true);
    final png = await Receipt.lines(await _printLines(zCopy: true));
    final ok = await Receipt.printPng(png, 'Report');
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) toast(context, 'Could not print. Check the printer in Settings.');
  }

  Future<void> _pdf() async {
    setState(() => _busy = true);
    final png = await Receipt.lines(await _printLines(zCopy: true));
    final (from, to) = _period;
    final where = await Receipt.pngPdf(png, 'Report-$from${from == to ? '' : '-to-$to'}', share: true);
    if (!mounted) return;
    setState(() => _busy = false);
    toast(context, where == null ? 'Could not make the PDF.' : 'PDF saved in Downloads/BRV POS.');
  }

  Future<void> _closeDay() async {
    final (day, _) = _period;
    final db = await Db.get();
    final waiting = (await db.rawQuery("SELECT COUNT(*) c FROM sales WHERE status = 'pending' AND day = ?", [day])).first['c'] as int? ?? 0;
    if (!mounted) return;
    if (waiting > 0) {
      toast(context, 'A sale on this day is still waiting for the VSCU. Retry it in Receipts first.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.lock_clock_rounded, color: C.gold, size: 40),
        title: Text('Close $_label (Z report)?'),
        content: const Text('This freezes the day\'s totals under the next Z number and prints the Z report. '
            'It is done once per day, normally at closing time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Close day')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    _z = await Reports.closeDay(day);
    Backup.auto();
    final png = await Receipt.lines(await _printLines(zCopy: false));
    await Receipt.printPng(png, 'Z report');
    if (!mounted) return;
    setState(() => _busy = false);
    toast(context, 'Day closed: Z report No. ${_z!['z_no']}.');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final today = Reports.ymd(DateTime.now());
    final (from, _) = _period;
    final canClose = _mode == 'day' && _z == null && from.compareTo(today) <= 0 && Session.i.admin;
    return Scaffold(
      appBar: AppBar(title: const Text('Sales reports')),
      body: ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 30), children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'day', label: Text('Daily'), icon: Icon(Icons.today_rounded)),
            ButtonSegment(value: 'month', label: Text('Monthly'), icon: Icon(Icons.calendar_month_rounded)),
            ButtonSegment(value: 'range', label: Text('Period'), icon: Icon(Icons.date_range_rounded)),
          ],
          selected: {_mode},
          onSelectionChanged: (v) {
            setState(() => _mode = v.first);
            _load();
          },
        ),
        const SizedBox(height: 8),
        Row(children: [
          if (_mode != 'range') IconButton(onPressed: () => _step(-1), icon: const Icon(Icons.chevron_left_rounded)),
          Expanded(
            child: TextButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.event_rounded, size: 18),
              label: Text(_label, style: h(16)),
            ),
          ),
          if (_mode != 'range')
            IconButton(
              onPressed: (_mode == 'day' ? from.compareTo(today) >= 0 : from.compareTo(today.substring(0, 8) + '01') >= 0)
                  ? null
                  : () => _step(1),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
        ]),
        if (_busy) const LinearProgressIndicator(color: C.brand),
        if (_error.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: C.redLight, borderRadius: BorderRadius.circular(14)),
            child: SelectableText('Could not build the report: $_error', style: const TextStyle(color: C.red)),
          )
        else if (d == null)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else ...[
          if (_mode == 'day')
            Container(
              margin: const EdgeInsets.only(top: 6, bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: _z == null ? C.goldLight : C.greenLight, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(_z == null ? Icons.lock_open_rounded : Icons.lock_rounded, color: _z == null ? C.goldDark : C.green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _z == null ? 'Day open: printing gives an X report.' : 'Day closed: Z report No. ${_z!['z_no']} by ${_z!['closed_by']}.',
                    style: TextStyle(color: _z == null ? C.goldDark : C.green, fontWeight: FontWeight.w700),
                  ),
                ),
              ]),
            ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [C.brand, C.brand2], begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('NET SALES', style: TextStyle(color: C.gold, fontWeight: FontWeight.w800, letterSpacing: 1)),
              Text(money(d.net), style: h(30, color: Colors.white)),
              const SizedBox(height: 10),
              Row(children: [
                _kpi('Receipts', '${d.salesCount}'),
                _kpi('Credit notes', '${d.creditCount}'),
                _kpi('VAT', money(d.vat, symbol: false)),
              ]),
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _print,
                icon: const Icon(Icons.print_rounded),
                label: Text(_mode == 'day' ? (_z == null ? 'Print X' : 'Print Z copy') : 'Print'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _pdf,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('PDF / share'),
              ),
            ),
          ]),
          if (canClose) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _closeDay,
              style: FilledButton.styleFrom(backgroundColor: C.gold),
              icon: const Icon(Icons.lock_clock_rounded),
              label: const Text('Close day (Z report)'),
            ),
          ],
          const SizedBox(height: 14),
          Section('Sales', [
            _row('Sales', money(d.salesTotal), sub: '${d.salesCount} receipts'),
            _row('Credit notes', '−${money(d.creditTotal)}', sub: '${d.creditCount}'),
            _row('Discounts given', money(d.discount)),
            if (d.firstInv != null) _row('Invoice numbers', '${d.firstInv} – ${d.lastInv}'),
            _row('Copies printed', '${d.copies}'),
            if (d.failedCount > 0) _row('Not signed (void)', '${d.failedCount}'),
          ]),
          Section('Tax', [
            for (final t in ['A', 'B', 'C', 'D', 'E'])
              if (d.tax[t]![2] != 0)
                _row(Kra.find(Kra.taxTypes, t)!.name, money(d.tax[t]![2]),
                    sub: 'Taxable ${money(d.tax[t]![0], symbol: false)} · VAT ${money(d.tax[t]![1], symbol: false)}'),
            _row('Total VAT', money(d.vat), bold: true),
          ]),
          Section('Payments', [
            if (d.payments.isEmpty) _row('No payments', ''),
            for (final e in d.payments.entries)
              _row(Kra.paymentName(e.key), money(e.value[1]), sub: '${e.value[0].toInt()} receipts'),
          ]),
          Section('Cashiers', [
            if (d.cashiers.isEmpty) _row('No sales', ''),
            for (final c in d.cashiers) _row('${c['name']}', money((c['amount'] as num).toDouble()), sub: '${c['count']} receipts'),
          ]),
          Section('Items sold (PLU)', [
            if (d.plu.isEmpty) _row('No items', ''),
            for (final p in d.plu)
              _row('${p['name']}', money((p['amount'] as num).toDouble()), sub: 'Qty ${qtyText((p['qty'] as num).toDouble())}'),
          ]),
        ],
      ]),
    );
  }

  Widget _kpi(String label, String value) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: h(17, color: Colors.white))),
        ]),
      );

  Widget _row(String a, String b, {String? sub, bool bold = false}) => ListTile(
        dense: true,
        title: Text(a, style: h(14.5, w: bold ? FontWeight.w800 : FontWeight.w600)),
        subtitle: sub == null ? null : Text(sub),
        trailing: Text(b, style: h(14.5, w: bold ? FontWeight.w800 : FontWeight.w700)),
      );
}
