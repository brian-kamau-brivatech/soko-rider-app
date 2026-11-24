import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'mgr_staff.dart';
import 'mgr_stock.dart';

String ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String dayLabel(DateTime d) {
  final today = DateTime.now();
  final t = DateTime(today.year, today.month, today.day);
  final x = DateTime(d.year, d.month, d.day);
  if (x == t) return 'Today';
  if (x == t.subtract(const Duration(days: 1))) return 'Yesterday';
  return '${_days[d.weekday - 1]} ${d.day}/${d.month}/${d.year}';
}

/// Manager app: reports, employees bills, staff rights and stock take / transfers.
class MgrMore extends StatelessWidget {
  const MgrMore({super.key});

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData icon, String title, String sub, Widget Function() page, {Color color = C.navy}) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: card(16),
          child: ListTile(
            leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, color: color)),
            title: Text(title, style: h(15.5, w: FontWeight.w700)),
            subtitle: Text(sub),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page())),
          ),
        );
    return Column(children: [
      Container(
        width: double.infinity,
        color: C.navy,
        padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 12, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Reports & staff', style: h(22, color: Colors.white)),
          Text('${Store.i.companyName} · ${Store.i.managerName}', style: const TextStyle(color: Color(0xFFC9D3E0), fontSize: 13)),
        ]),
      ),
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
          Text('Reports', style: h(15, color: C.muted)),
          const SizedBox(height: 8),
          tile(Icons.bar_chart_rounded, 'Sales report', 'By day, payment, cashier, category and item', () => const SalesReportScreen(),
              color: C.green),
          tile(Icons.inventory_rounded, 'Stock report (per day)', 'Opening and closing of each item, in, out and sold',
              () => const StockReportScreen(), color: C.green),
          const SizedBox(height: 8),
          Text('Staff', style: h(15, color: C.muted)),
          const SizedBox(height: 8),
          tile(Icons.badge_rounded, 'Employees bills', 'Credit sales to staff: open and cleared', () => const StaffBillsScreen(),
              color: C.amber),
          tile(Icons.admin_panel_settings_rounded, 'Staff rights', 'Waiters (orders and bills) and cashiers (payment)',
              () => const StaffRightsScreen(), color: C.blue),
          const SizedBox(height: 8),
          Text('Stock', style: h(15, color: C.muted)),
          const SizedBox(height: 8),
          tile(Icons.fact_check_rounded, 'Stock take', 'Enter the exact stock of the main store, bar or kitchen',
              () => const StockTakeScreen()),
          tile(Icons.local_shipping_rounded, 'Transfer to bar / kitchen', 'Move stock from the main store now',
              () => const TransferScreen()),
        ]),
      ),
    ]);
  }
}

/// Point of Sale picker shared by the reports (0 = all, where allowed).
Future<List<Map<String, dynamic>>> loadConfigs() async => ll((await Api.call('/utange/mgr/configs', {}))['configs']);

// ---------------------------------------------------------------------------
// Sales report
// ---------------------------------------------------------------------------
class SalesReportScreen extends StatefulWidget {
  const SalesReportScreen({super.key});
  @override
  State<SalesReportScreen> createState() => _SalesReportScreenState();
}

class _SalesReportScreenState extends State<SalesReportScreen> {
  DateTimeRange _range = DateTimeRange(start: DateTime.now(), end: DateTime.now());
  String _preset = 'today';
  List<Map<String, dynamic>> _configs = const [];
  int _config = 0;
  Map<String, dynamic>? _r;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    loadConfigs().then((c) {
      if (mounted) setState(() => _configs = c);
    }).catchError((_) {});
    _load();
  }

  void _setPreset(String p) {
    final now = DateTime.now();
    final t = DateTime(now.year, now.month, now.day);
    setState(() {
      _preset = p;
      _range = switch (p) {
        'yesterday' => DateTimeRange(start: t.subtract(const Duration(days: 1)), end: t.subtract(const Duration(days: 1))),
        'week' => DateTimeRange(start: t.subtract(const Duration(days: 6)), end: t),
        'month' => DateTimeRange(start: DateTime(t.year, t.month, 1), end: t),
        _ => DateTimeRange(start: t, end: t),
      };
    });
    _load();
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
        context: context, firstDate: DateTime(now.year - 2), lastDate: now, initialDateRange: _range);
    if (r == null) return;
    setState(() {
      _range = r;
      _preset = 'custom';
    });
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Api.call('/utange/mgr/sales_report',
          {'config_id': _config, 'date_from': ymd(_range.start), 'date_to': ymd(_range.end)});
      if (mounted) setState(() => _r = r);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _section(String title, List<Map<String, dynamic>> rows, {bool showQty = false, bool showCount = false}) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: h(16)),
        const SizedBox(height: 6),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(child: Text(ss(r['name']).isNotEmpty ? ss(r['name']) : dayLabel(DateTime.parse(ss(r['day']))))),
              if (showQty) SizedBox(width: 70, child: Text(qty(dd(r['qty'])), textAlign: TextAlign.right, style: const TextStyle(color: C.muted))),
              if (showCount)
                SizedBox(width: 70, child: Text('${ii(r['count'])} sales', textAlign: TextAlign.right, style: const TextStyle(color: C.muted))),
              SizedBox(width: 100, child: Text(ksh(dd(r['total'])), textAlign: TextAlign.right, style: h(14))),
            ]),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return Scaffold(
      appBar: bar('Sales report', actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))]),
      body: RefreshIndicator(
        color: C.green,
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final p in const [('today', 'Today'), ('yesterday', 'Yesterday'), ('week', '7 days'), ('month', 'This month')])
              ChoiceChip(label: Text(p.$2), selected: _preset == p.$1, onSelected: (_) => _setPreset(p.$1)),
            ActionChip(
              avatar: const Icon(Icons.date_range_rounded, size: 18),
              label: Text(_preset == 'custom' ? '${ymd(_range.start)} → ${ymd(_range.end)}' : 'Dates'),
              onPressed: _pickRange,
            ),
          ]),
          if (_configs.length > 1)
            DropdownButton<int>(
              value: _config,
              isExpanded: true,
              items: [
                const DropdownMenuItem(value: 0, child: Text('All points of sale')),
                for (final c in _configs) DropdownMenuItem(value: ii(c['id']), child: Text(ss(c['name']))),
              ],
              onChanged: (v) {
                setState(() => _config = v ?? 0);
                _load();
              },
            ),
          const SizedBox(height: 8),
          if (_error != null) EmptyNote(Icons.wifi_off_rounded, _error!),
          if (r == null && _error == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: C.green))),
          if (r != null) ...[
            Opacity(
              opacity: _loading ? 0.5 : 1,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: C.navy, borderRadius: BorderRadius.circular(18)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(ss(r['from']) == ss(r['to']) ? dayLabel(DateTime.parse(ss(r['from']))) : '${r['from']} → ${r['to']}',
                      style: const TextStyle(color: Color(0xFFC9D3E0))),
                  Text(ksh(dd(r['total'])), style: h(30, color: Colors.white)),
                  Text('${ii(r['count'])} sales · tax ${ksh(dd(r['tax']))}', style: const TextStyle(color: Color(0xFFC9D3E0))),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _stat('Employees bills', ksh(dd(r['staff_bills'])), '${ii(r['staff_bill_count'])} bills', C.amber)),
              const SizedBox(width: 10),
              Expanded(child: _stat('Open bills (not paid)', ksh(dd(r['open_bills'])), '${ii(r['open_bill_count'])} in open shifts', C.red)),
            ]),
            const SizedBox(height: 12),
            _section('By day', ll(r['days']), showCount: true),
            _section('By payment', ll(r['by_method'])),
            _section('By cashier / waiter', ll(r['by_cashier']), showCount: true),
            _section('By category', ll(r['by_category'])),
            _section('Items sold', ll(r['products']), showQty: true),
          ],
        ]),
      ),
    );
  }

  Widget _stat(String label, String value, String sub, Color color) => Container(
        padding: const EdgeInsets.all(12),
        decoration: card(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: C.muted, fontSize: 12.5)),
          Text(value, style: h(18, color: color)),
          Text(sub, style: const TextStyle(color: C.muted, fontSize: 11.5)),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Stock report per day
// ---------------------------------------------------------------------------
class StockReportScreen extends StatefulWidget {
  const StockReportScreen({super.key});
  @override
  State<StockReportScreen> createState() => _StockReportScreenState();
}

class _StockReportScreenState extends State<StockReportScreen> {
  DateTime _day = DateTime.now();
  List<Map<String, dynamic>> _configs = const [];
  int _config = 0;
  Map<String, dynamic>? _r;
  String? _error;
  String _q = '';
  bool _onlyDiff = false;

  @override
  void initState() {
    super.initState();
    loadConfigs().then((c) {
      if (mounted) setState(() => _configs = c);
    }).catchError((_) {});
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await Api.call('/utange/mgr/stock_report', {'config_id': _config, 'day': ymd(_day)});
      if (mounted) setState(() => _r = r);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  void _shift(int days) {
    final n = _day.add(Duration(days: days));
    if (n.isAfter(DateTime.now())) return;
    setState(() {
      _day = n;
      _r = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final q = _q.trim().toLowerCase();
    final items = ll(r?['items'])
        .where((i) => q.isEmpty || ss(i['name']).toLowerCase().contains(q))
        .where((i) => !_onlyDiff || dd(i['close_diff']).abs() > 0.0001 || dd(i['open_diff']).abs() > 0.0001)
        .toList();
    final shifts = ll(r?['shifts']);
    return Scaffold(
      appBar: bar('Stock report', actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))]),
      body: Column(children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Column(children: [
            Row(children: [
              IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left_rounded)),
              Expanded(
                child: TextButton(
                  onPressed: () async {
                    final d = await showDatePicker(
                        context: context, initialDate: _day, firstDate: DateTime(_day.year - 2), lastDate: DateTime.now());
                    if (d == null) return;
                    setState(() {
                      _day = d;
                      _r = null;
                    });
                    _load();
                  },
                  child: Text(dayLabel(_day), style: h(16)),
                ),
              ),
              IconButton(onPressed: () => _shift(1), icon: const Icon(Icons.chevron_right_rounded)),
            ]),
            if (_configs.length > 1)
              DropdownButton<int>(
                value: _config == 0 ? ii(_configs.first['id']) : _config,
                isExpanded: true,
                items: [for (final c in _configs) DropdownMenuItem(value: ii(c['id']), child: Text(ss(c['name'])))],
                onChanged: (v) {
                  setState(() {
                    _config = v ?? 0;
                    _r = null;
                  });
                  _load();
                },
              ),
            Row(children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _q = v),
                  decoration: InputDecoration(
                    hintText: 'Search item',
                    prefixIcon: const Icon(Icons.search_rounded),
                    isDense: true,
                    filled: true,
                    fillColor: C.bg,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(label: const Text('Differences'), selected: _onlyDiff, onSelected: (v) => setState(() => _onlyDiff = v)),
            ]),
          ]),
        ),
        Expanded(
          child: Loader(
            loading: r == null,
            error: _error,
            onRetry: _load,
            child: () => RefreshIndicator(
              color: C.green,
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(12, 10, 12, 24), children: [
                if (shifts.isEmpty)
                  const EmptyNote(Icons.event_busy_rounded, 'No shift opened on this day.')
                else ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: card(),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        Expanded(child: Text('${shifts.length} shift${shifts.length == 1 ? '' : 's'} · ${ss(r?['config'])}', style: h(15))),
                        Text(ksh(dd(r?['sales'])), style: h(15, color: C.green)),
                      ]),
                      const SizedBox(height: 4),
                      for (final s in shifts)
                        Text(
                            '${ss(s['name'])}: opened ${_hm(ss(s['opened']))}${ss(s['by_open']).isEmpty ? '' : ' by ${s['by_open']}'}'
                            '${ss(s['closed']).isEmpty ? ' · still open' : ' · closed ${_hm(ss(s['closed']))}${ss(s['by_close']).isEmpty ? '' : ' by ${s['by_close']}'}'}',
                            style: const TextStyle(color: C.muted, fontSize: 12.5)),
                      const Divider(color: C.line),
                      Row(children: [
                        Expanded(child: Text('Opening differences', style: const TextStyle(color: C.muted))),
                        Text(ksh(dd(r?['open_variance'])), style: h(14, color: dd(r?['open_variance']) < 0 ? C.red : C.ink)),
                      ]),
                      Row(children: [
                        Expanded(child: Text('Closing variance', style: const TextStyle(color: C.muted))),
                        Text(ksh(dd(r?['variance'])), style: h(14, color: dd(r?['variance']) < 0 ? C.red : C.ink)),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  for (final i in items) _row(i),
                  if (items.isEmpty) const EmptyNote(Icons.search_off_rounded, 'Nothing matches.'),
                ],
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  String _hm(String dt) => dt.length >= 16 ? dt.substring(11, 16) : dt;

  Widget _row(Map<String, dynamic> l) {
    final closing = dn(l['closing']);
    final diff = dd(l['close_diff']);
    final openDiff = dd(l['open_diff']);
    final bad = diff.abs() > 0.0001;
    Widget cell(String label, String value, {Color? color}) => Expanded(
          child: Column(children: [
            Text(value, style: h(14, color: color ?? C.ink)),
            Text(label, style: const TextStyle(color: C.muted, fontSize: 11)),
          ]),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: bad ? (diff < 0 ? C.red : C.amber) : (openDiff.abs() > 0.0001 ? C.amber : C.line)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(ss(l['name']), style: h(14, w: FontWeight.w700))),
          if (ss(l['point']).isNotEmpty) Padding(padding: const EdgeInsets.only(right: 8), child: Pill(ss(l['point']), fg: C.navy, bg: C.blueLight)),
          Text(ksh(dd(l['amount'])), style: h(13.5, color: C.green)),
        ]),
        if (openDiff.abs() > 0.0001)
          Text('Opening: system ${qty(dd(l['system_open']))}, counted ${qty(dd(l['opening']))} (${signed(openDiff)})',
              style: const TextStyle(color: C.amber, fontSize: 12.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Row(children: [
          cell('Opening', qty(dd(l['opening']))),
          cell('In', '+${qty(dd(l['received']))}', color: C.green),
          cell('Out', '−${qty(dd(l['sent_out']))}', color: C.red),
          cell('Sold', qty(dd(l['sold']))),
          cell(closing == null ? 'Now (exp.)' : 'Closing', closing == null ? qty(dd(l['expected'])) : qty(closing)),
          cell('Diff', closing == null ? '—' : signed(diff), color: bad ? (diff < 0 ? C.red : C.amber) : C.green),
        ]),
      ]),
    );
  }
}
