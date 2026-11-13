import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'mgr_shell.dart';

/// Shift stock sheets: opening count vs received vs sold vs closing count.
class MgrSheets extends StatefulWidget {
  const MgrSheets({super.key});
  @override
  State<MgrSheets> createState() => _MgrSheetsState();
}

class _MgrSheetsState extends State<MgrSheets> {
  List<SheetRow>? _list;
  String? _error;
  bool _onlyDiffs = false;

  @override
  void initState() {
    super.initState();
    _load();
    mgrTab.addListener(_onTab);
  }

  @override
  void dispose() {
    mgrTab.removeListener(_onTab);
    super.dispose();
  }

  void _onTab() {
    if (mgrTab.value == 2) _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.call('/utange/mgr/sheets', {'only_diffs': _onlyDiffs});
      if (mounted) {
        setState(() {
          _list = ll(r['sheets']).map(SheetRow.fromJson).toList();
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: C.green,
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
          Text('Stock sheets', style: h(22)),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('All shifts')),
              ButtonSegment(value: true, label: Text('With differences'), icon: Icon(Icons.warning_amber_rounded)),
            ],
            selected: {_onlyDiffs},
            showSelectedIcon: false,
            onSelectionChanged: (v) {
              setState(() {
                _onlyDiffs = v.first;
                _list = null;
              });
              _load();
            },
          ),
          const SizedBox(height: 12),
          if (list == null && _error == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: C.green)))
          else if (list == null)
            EmptyNote(Icons.wifi_off_rounded, _error!)
          else if (list.isEmpty)
            const EmptyNote(Icons.fact_check_outlined, 'No stock sheets.')
          else
            for (final s in list) SheetTile(s),
        ]),
      ),
    );
  }
}

class SheetTile extends StatelessWidget {
  final SheetRow s;
  const SheetTile(this.s, {super.key});
  @override
  Widget build(BuildContext context) {
    final open = s.state == 'open';
    final bad = s.closeDiffs > 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: bad ? C.red : C.line, width: bad ? 1.4 : 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        title: Row(children: [
          Expanded(child: Text('${s.name} · ${s.config}', style: h(14.5))),
          if (open) const Pill('OPEN') else if (bad) Pill('${s.closeDiffs} DIFF', fg: C.red, bg: C.redLight),
        ]),
        subtitle: Text([
          '${s.opened.length >= 16 ? s.opened.substring(0, 16) : s.opened}${s.closed.isEmpty ? '' : ' → ${s.closed.length >= 16 ? s.closed.substring(11, 16) : s.closed}'}',
          [if (s.byOpen.isNotEmpty) 'Opened by ${s.byOpen}', if (s.byClose.isNotEmpty) 'closed by ${s.byClose}'].join(', '),
          'Sales ${ksh(s.sales)}${open ? '' : ' · variance ${ksh(s.variance)}'}${s.openDiffs > 0 ? ' · ${s.openDiffs} opening diffs' : ''}',
        ].where((x) => x.isNotEmpty).join('\n')),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SheetDetail(sheetId: s.id))),
      ),
    );
  }
}

class SheetDetail extends StatefulWidget {
  final int sheetId;
  const SheetDetail({super.key, required this.sheetId});
  @override
  State<SheetDetail> createState() => _SheetDetailState();
}

class _SheetDetailState extends State<SheetDetail> {
  SheetRow? _s;
  String? _error;
  bool _onlyIssues = false;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.call('/utange/mgr/sheet', {'sheet_id': widget.sheetId});
      if (mounted) {
        setState(() {
          _s = SheetRow.fromJson(Map<String, dynamic>.from(r['sheet'] as Map));
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      appBar: bar(s?.name ?? 'Stock sheet', actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))]),
      body: RefreshIndicator(
        color: C.green,
        onRefresh: _load,
        child: Loader(loading: s == null, error: _error, onRetry: _load, child: () => _body(s!)),
      ),
    );
  }

  Widget _body(SheetRow s) {
    final open = s.state == 'open';
    final q = _q.trim().toLowerCase();
    final lines = s.lines.where((l) {
      if (q.isNotEmpty && !ss(l['name']).toLowerCase().contains(q)) return false;
      if (!_onlyIssues) return true;
      return dd(l['open_diff']).abs() > 0.0001 || (dn(l['diff']) ?? 0).abs() > 0.0001;
    }).toList();
    final soldValue = s.lines.fold<double>(0, (a, l) => a + dd(l['amount']));
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: open ? C.green : C.navy, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${s.config} · ${s.session}', style: h(17, color: Colors.white)),
          Text('${s.location} · ${open ? 'shift open (live)' : 'closed ${s.closed}'}', style: const TextStyle(color: Color(0xFFE6EEF7))),
          if (s.outside)
            const Text('Opened without a count on the handheld', style: TextStyle(color: Color(0xFFFDE68A), fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Row(children: [
            _stat('Sales', ksh(soldValue)),
            _stat('Opening diffs', '${s.openDiffs}'),
            _stat(open ? 'Closing' : 'Closing diffs', open ? '—' : '${s.closeDiffs}'),
          ]),
          if (!open) ...[
            const SizedBox(height: 8),
            Text('Variance at selling price: ${ksh(s.variance)}',
                style: h(15, color: s.variance < 0 ? const Color(0xFFFECACA) : Colors.white)),
          ],
        ]),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: TextField(
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              hintText: 'Search item',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilterChip(label: const Text('Differences'), selected: _onlyIssues, onSelected: (v) => setState(() => _onlyIssues = v)),
      ]),
      const SizedBox(height: 8),
      if (lines.isEmpty) const EmptyNote(Icons.check_circle_outline_rounded, 'Nothing to show.'),
      for (final l in lines) _line(l, open),
    ]);
  }

  Widget _stat(String a, String b) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(b, style: h(17, color: Colors.white)),
          Text(a, style: const TextStyle(color: Color(0xFFE6EEF7), fontSize: 12)),
        ]),
      );

  Widget _line(Map<String, dynamic> l, bool open) {
    final openDiff = dd(l['open_diff']);
    final diff = dn(l['diff']);
    final bad = (diff ?? 0) < -0.0001;
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
        border: Border.all(color: bad ? C.red : (openDiff.abs() > 0.0001 ? C.amber : C.line)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(ss(l['name']), style: h(14, w: FontWeight.w700))),
          Text(ksh(dd(l['amount'])), style: h(13.5, color: C.green)),
        ]),
        if (openDiff.abs() > 0.0001)
          Text('Opening: system ${qty(dd(l['system_open']))}, counted ${qty(dd(l['opening']))} (${signed(openDiff)})',
              style: const TextStyle(color: C.amber, fontSize: 12.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Row(children: [
          cell('Opening', qty(dd(l['opening']))),
          cell('In', qty(dd(l['received']))),
          cell('Sold', qty(dd(l['sold']))),
          cell('Expected', qty(dd(l['expected']))),
          if (open)
            cell('On hand', qty(dd(l['on_hand'])))
          else
            cell('Closing', diff == null ? '—' : qty(dd(l['closing']))),
          if (!open) cell('Diff', diff == null ? '' : signed(diff), color: bad ? C.red : (diff != null && diff > 0.0001 ? C.amber : C.green)),
        ]),
      ]),
    );
  }
}
