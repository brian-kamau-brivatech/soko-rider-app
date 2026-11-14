import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../idle.dart';
import '../ui.dart';

/// The stock sheet count: every item must get a number before the shift opens (phase 'open')
/// or closes (phase 'close'). Returns {counts: [{product_id, qty}], reason, manager_pin?} or null when cancelled.
/// Differences need a manager: a manager's PIN now, or "Send to manager" (approved later in the Manager app / Odoo).
class CountScreen extends StatefulWidget {
  final String phase; // open | close
  const CountScreen({super.key, required this.phase});
  @override
  State<CountScreen> createState() => _CountScreenState();
}

class _CountScreenState extends State<CountScreen> {
  List<CountItem>? _items;
  String? _error;
  String _location = '';
  String _q = '';
  bool _onlyLeft = false;
  String _point = '';
  bool _canApprove = false; // the signed-in cashier is a chosen approver: no PIN step
  final Map<int, TextEditingController> _c = {};

  bool get _open => widget.phase == 'open';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await Api.call('/utange/pos/sheet', Store.i.base({'phase': widget.phase}));
      final items = ll(r['items']).map(CountItem.fromJson).toList();
      if (!mounted) return;
      setState(() {
        _items = items;
        _location = ss(r['location']);
        _canApprove = r['can_approve'] == true;
        for (final i in items) {
          _c.putIfAbsent(i.productId, () => TextEditingController());
        }
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  double _ref(CountItem i) => _open ? i.system : i.expected;
  double? _val(CountItem i) => double.tryParse((_c[i.productId]?.text ?? '').trim());
  int get _done => (_items ?? const <CountItem>[]).where((i) => _val(i) != null).length;

  Future<void> _fillRest() async {
    final left = (_items ?? const <CountItem>[]).where((i) => _val(i) == null).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Fill $left items?'),
        content: Text(_open
            ? 'The $left items not typed get the system quantity. Only do this if you have checked them and they are correct.'
            : 'The $left items not typed get the expected quantity. Only do this if you have checked them and they are correct.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('I have checked them')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      for (final i in _items ?? const <CountItem>[]) {
        if (_val(i) == null) _c[i.productId]!.text = qty(_ref(i));
      }
    });
  }

  Future<void> _confirm() async {
    final items = _items ?? const <CountItem>[];
    final diffs = items.where((i) => (_val(i)! - _ref(i)).abs() > 0.0001).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_open ? 'Confirm opening stock' : 'Confirm closing stock'),
        content: SingleChildScrollView(
          child: Text(diffs.isEmpty
              ? 'All ${items.length} items match. Confirm?'
              : '${diffs.length} items differ from ${_open ? 'the system' : 'expected'}:\n\n${diffs.take(15).map((i) => '• ${i.name}: ${signed(_val(i)! - _ref(i))}').join('\n')}'
                  '${diffs.length > 15 ? '\n…' : ''}'
                  '${_open ? '' : '\n\nVariance at selling price: ${ksh(diffs.fold<double>(0, (s, i) => s + (_val(i)! - _ref(i)) * i.price))}'}'
                  '\n\nThe manager is alerted about these differences.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Recount')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final counts = <Map<String, dynamic>>[for (final i in items) {'product_id': i.productId, 'qty': _val(i)}];
    if (diffs.isEmpty || _canApprove) {
      Navigator.of(context).pop(<String, dynamic>{'counts': counts});
      return;
    }
    final approval = await showDialog<Map<String, String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ApprovalDialog(diffCount: diffs.length),
    );
    if (approval == null || !mounted) return;
    Navigator.of(context).pop(<String, dynamic>{
      'counts': counts,
      'reason': approval['reason'] ?? '',
      if ((approval['pin'] ?? '').isNotEmpty) 'manager_pin': approval['pin'],
    });
  }

  @override
  Widget build(BuildContext context) {
    final all = _items ?? const <CountItem>[];
    final q = _q.trim().toLowerCase();
    final shown = all
        .where((i) => q.isEmpty || i.name.toLowerCase().contains(q))
        .where((i) => !_onlyLeft || _val(i) == null)
        .where((i) => _point.isEmpty || i.point == _point)
        .toList();
    final complete = all.isNotEmpty && _done == all.length;
    return Scaffold(
      appBar: bar(_open ? 'Opening stock count' : 'Closing stock count'),
      body: Loader(
        loading: _items == null,
        error: _error,
        onRetry: _load,
        child: () => Column(children: [
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$_location · $_done of ${all.length} counted', style: h(14.5)),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: all.isEmpty ? 0 : _done / all.length,
                color: C.green,
                backgroundColor: C.line,
                minHeight: 6,
                borderRadius: BorderRadius.circular(6),
              ),
              const SizedBox(height: 8),
              Text(
                _open
                    ? 'Count what is really on the shelf and type it. "System" is what Odoo has. Differences need a manager.'
                    : 'Type what is remaining. Balance = Opening + In − Out − Sold (In/Out = requisitions and transfers). '
                        'Differences need a manager.',
                style: const TextStyle(color: C.muted, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
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
                if (all.map((i) => i.point).toSet().length > 1)
                  PopupMenuButton<String>(
                    tooltip: 'Bar / Kitchen',
                    icon: Icon(Icons.filter_list_rounded, color: _point.isEmpty ? C.muted : C.green),
                    onSelected: (v) => setState(() => _point = v),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: '', child: Text('All')),
                      for (final pt in all.map((i) => i.point).toSet()) PopupMenuItem(value: pt, child: Text(pt)),
                    ],
                  ),
                FilterChip(
                  label: const Text('Not counted'),
                  selected: _onlyLeft,
                  onSelected: (v) => setState(() => _onlyLeft = v),
                ),
              ]),
            ]),
          ),
          Expanded(
            child: all.isEmpty
                ? const EmptyNote(Icons.inventory_2_outlined,
                    'No stock-tracked items for this POS. In Odoo, set the bar items to "Storable".')
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 110),
                    itemCount: shown.length,
                    itemBuilder: (_, n) => _row(shown[n]),
                  ),
          ),
        ]),
      ),
      bottomSheet: _items == null || all.isEmpty
          ? null
          : Material(
              color: Colors.white,
              elevation: 8,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: Row(children: [
                    if (!complete)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _fillRest,
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
                          child: Text(_open ? 'Rest = system' : 'Rest = expected', textAlign: TextAlign.center),
                        ),
                      ),
                    if (!complete) const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: primaryButton(complete ? 'Confirm count' : '${all.length - _done} left', complete ? _confirm : null,
                          icon: Icons.fact_check_rounded),
                    ),
                  ]),
                ),
              ),
            ),
    );
  }

  Widget _row(CountItem i) {
    final v = _val(i);
    final diff = v == null ? null : v - _ref(i);
    final bad = diff != null && diff.abs() > 0.0001;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: v == null ? C.line : (bad ? C.amber : C.green), width: v == null ? 1 : 1.5),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(i.name, style: h(14, w: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              (i.point.isEmpty ? '' : '${i.point} · ') +
              (_open
                  ? 'System ${qty(i.system)}${i.lastClose != null ? ' · last close ${qty(i.lastClose!)}' : ''}'
                  : 'Opening ${qty(i.opening)} · In +${qty(i.received)} · Out −${qty(i.sentOut)} · Sold ${qty(i.sold)} → Balance ${qty(i.expected)}'),
              style: const TextStyle(color: C.muted, fontSize: 12.5),
            ),
            if (bad)
              Text('Difference ${signed(diff!)}', style: TextStyle(color: diff! < 0 ? C.red : C.amber, fontWeight: FontWeight.w700, fontSize: 12.5)),
          ]),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 86,
          child: TextField(
            controller: _c[i.productId],
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.center,
            style: h(18),
            onChanged: (_) {
              IdleLock.touch();
              setState(() {});
            },
            decoration: InputDecoration(
              hintText: '—',
              isDense: true,
              filled: true,
              fillColor: C.bg,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Differences found: a manager approves now with their PIN, or the count is sent to the manager.
class _ApprovalDialog extends StatefulWidget {
  final int diffCount;
  const _ApprovalDialog({required this.diffCount});
  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  final _reason = TextEditingController();
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    _pin.dispose();
    super.dispose();
  }

  bool get _reasonOk => _reason.text.trim().length >= 3;

  Future<void> _approve() async {
    if (!_reasonOk || _pin.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await Api.call('/utange/pos/check_manager_pin', Store.i.base({'manager_pin': _pin.text.trim()}));
      if (!mounted) return;
      if (r['ok'] == true) {
        Navigator.pop(context, {'reason': _reason.text.trim(), 'pin': _pin.text.trim()});
      } else {
        setState(() => _error = ss(r['error']).isEmpty ? 'Wrong manager PIN.' : ss(r['error']));
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Manager approval'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${widget.diffCount} items differ. Odoo\'s stock only changes when a manager approves.'),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Reason (e.g. 1 soda broken)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: 'Manager PIN (manager is here)', errorText: _error),
          ),
          const SizedBox(height: 8),
          const Text('No manager here? Send to manager: the manager approves or rejects in the Manager app or Odoo.',
              style: TextStyle(color: C.muted, fontSize: 12.5)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Recount')),
        TextButton(
          onPressed: _reasonOk && !_busy ? () => Navigator.pop(context, {'reason': _reason.text.trim(), 'pin': ''}) : null,
          child: const Text('Send to manager'),
        ),
        FilledButton(
          onPressed: _reasonOk && _pin.text.trim().isNotEmpty && !_busy ? _approve : null,
          child: const Text('Approve'),
        ),
      ],
    );
  }
}
