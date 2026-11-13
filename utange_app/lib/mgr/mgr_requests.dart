import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'mgr_shell.dart';

/// Requisitions from the bar: compare with the shift's opening count and sales, then approve or reject.
class MgrRequests extends StatefulWidget {
  const MgrRequests({super.key});
  @override
  State<MgrRequests> createState() => _MgrRequestsState();
}

class _MgrRequestsState extends State<MgrRequests> {
  static const _filters = [('submitted', 'To approve'), ('approved', 'To issue'), ('done', 'Issued'), ('', 'All')];
  String _state = 'submitted';
  List<Requisition>? _list;
  String? _error;

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
    if (mgrTab.value == 1) _load();
  }

  Future<void> _load() async {
    final st = _state;
    try {
      final r = await Api.call('/utange/mgr/requisitions', {if (st.isNotEmpty) 'state': st});
      if (mounted && st == _state) {
        setState(() {
          _list = ll(r['requisitions']).map(Requisition.fromJson).toList();
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
          Text('Requests', style: h(22)),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final f in _filters)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f.$2),
                    selected: _state == f.$1,
                    onSelected: (_) {
                      setState(() {
                        _state = f.$1;
                        _list = null;
                      });
                      _load();
                    },
                    selectedColor: C.navy,
                    showCheckmark: false,
                    labelStyle: h(13.5, w: FontWeight.w700, color: _state == f.$1 ? Colors.white : C.ink),
                    backgroundColor: Colors.white,
                    side: BorderSide(color: _state == f.$1 ? C.navy : C.line),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          if (list == null && _error == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: C.green)))
          else if (list == null)
            EmptyNote(Icons.wifi_off_rounded, _error!)
          else if (list.isEmpty)
            const EmptyNote(Icons.assignment_turned_in_outlined, 'Nothing here.')
          else
            for (final r in list) _tile(r),
        ]),
      ),
    );
  }

  Widget _tile(Requisition r) {
    final (fg, bg) = reqColors(r.state);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: card(),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        title: Row(children: [
          Expanded(child: Text(r.name, style: h(15))),
          Pill(r.stateLabel, fg: fg, bg: bg),
        ]),
        subtitle: Text('${r.date}\n${r.by.isEmpty ? r.config : '${r.by} · ${r.config}'} · ${r.items} items'
            '${r.note.isEmpty ? '' : '\n“${r.note}”'}'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RequestDetail(id: r.id)));
          _load();
        },
      ),
    );
  }
}

class RequestDetail extends StatefulWidget {
  final int id;
  const RequestDetail({super.key, required this.id});
  @override
  State<RequestDetail> createState() => _RequestDetailState();
}

class _RequestDetailState extends State<RequestDetail> {
  Requisition? _r;
  String? _error;
  bool _busy = false;
  final _note = TextEditingController();
  final Map<int, TextEditingController> _qty = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    for (final c in _qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await Api.call('/utange/mgr/requisition', {'requisition_id': widget.id});
      final r = Requisition.fromJson(Map<String, dynamic>.from(res['requisition'] as Map));
      if (!mounted) return;
      setState(() {
        _r = r;
        _error = null;
        for (var n = 0; n < r.lines.length; n++) {
          _qty.putIfAbsent(n, () => TextEditingController(text: qty(dd(r.lines[n]['qty']))));
        }
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  Future<void> _act(String action) async {
    final r = _r!;
    if (action == 'reject') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Reject ${r.name}?'),
          content: const Text('Write the reason in the manager note so the bar knows why.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(backgroundColor: C.red),
                child: const Text('Reject')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      final qtys = <String, double>{};
      for (var n = 0; n < r.lines.length; n++) {
        final v = double.tryParse(_qty[n]?.text.trim() ?? '');
        if (v != null && (v - dd(r.lines[n]['qty'])).abs() > 0.0001) qtys['$n'] = v;
      }
      final res = await Api.call('/utange/mgr/requisition_action', {
        'requisition_id': r.id,
        'action': action,
        if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
        if (action == 'approve' && qtys.isNotEmpty) 'qtys': qtys,
      });
      if (!mounted) return;
      toast(context, ss(res['message']));
      setState(() => _r = Requisition.fromJson(Map<String, dynamic>.from(res['requisition'] as Map)));
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
      await Store.i.handle(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return Scaffold(
      appBar: bar(r?.name ?? 'Request'),
      body: Loader(loading: r == null, error: _error, onRetry: _load, child: () => _body(r!)),
    );
  }

  Widget _body(Requisition r) {
    final waiting = r.state == 'submitted';
    final (fg, bg) = reqColors(r.state);
    final shift = r.shift;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 30), children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: Text(r.by.isEmpty ? r.config : r.by, style: h(16))), Pill(r.stateLabel, fg: fg, bg: bg)]),
          Text('${r.date} · ${r.from} → ${r.to}', style: const TextStyle(color: C.muted)),
          if (r.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('“${r.note}”')),
          if (shift != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Compared with shift ${ss(shift['session'])}${ss(shift['sheet']).isEmpty ? '' : ' (stock sheet ${ss(shift['sheet'])})'}',
                  style: const TextStyle(color: C.navy, fontWeight: FontWeight.w600)),
            ),
          if (r.transfer.isNotEmpty) Text('Transfer ${r.transfer}${r.approvedBy.isEmpty ? '' : ' · approved by ${r.approvedBy}'}'),
          if (r.managerNote.isNotEmpty) Text('Manager note: ${r.managerNote}'),
        ]),
      ),
      const SizedBox(height: 12),
      for (var n = 0; n < r.lines.length; n++) _line(n, r.lines[n], waiting),
      if (waiting) ...[
        const SizedBox(height: 8),
        TextField(controller: _note, decoration: const InputDecoration(labelText: 'Manager note (optional)', prefixIcon: Icon(Icons.notes_rounded))),
        const SizedBox(height: 16),
        primaryButton('Approve and send to store', () => _act('approve'), icon: Icons.check_circle_rounded, busy: _busy),
        const SizedBox(height: 10),
        SizedBox(
          height: 50,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _act('reject'),
            icon: const Icon(Icons.block_rounded),
            label: const Text('Reject'),
            style: OutlinedButton.styleFrom(foregroundColor: C.red, side: const BorderSide(color: C.red)),
          ),
        ),
      ],
    ]);
  }

  Widget _line(int n, Map<String, dynamic> l, bool editable) {
    Widget cell(String label, String value, {Color? color}) => Expanded(
          child: Column(children: [
            Text(value, style: h(14, color: color ?? C.ink)),
            Text(label, textAlign: TextAlign.center, style: const TextStyle(color: C.muted, fontSize: 11)),
          ]),
        );
    final opening = dn(l['shift_opening']);
    final sold = dn(l['shift_sold']);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: card(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(ss(l['name']), style: h(14.5, w: FontWeight.w700))),
          if (editable)
            SizedBox(
              width: 92,
              child: TextField(
                controller: _qty[n],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textAlign: TextAlign.center,
                style: h(16),
                decoration: InputDecoration(
                  labelText: 'Approve',
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            )
          else
            Text(dd(l['issued']) > 0 ? 'Issued ${qty(dd(l['issued']))}' : 'Asked ${qty(dd(l['qty']))}', style: h(14)),
        ]),
        Text('Asked for ${qty(dd(l['qty']))} ${ss(l['uom'])}${ss(l['note']).isEmpty ? '' : ' · ${ss(l['note'])}'}',
            style: const TextStyle(color: C.muted, fontSize: 12.5)),
        const SizedBox(height: 8),
        Row(children: [
          cell('Shift\nopening', opening == null ? '—' : qty(opening)),
          cell('Sold this\nshift', sold == null ? '—' : qty(sold)),
          cell('In bar\nnow', qty(dd(l['bar_now'])), color: dd(l['bar_now']) <= 0 ? C.red : null),
          cell('In store\nnow', qty(dd(l['store_now'])), color: dd(l['store_now']) < dd(l['qty']) ? C.amber : null),
          cell('Sold\n7 days', qty(dd(l['sold_7_days']))),
        ]),
      ]),
    );
  }
}
