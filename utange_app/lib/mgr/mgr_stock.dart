import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'mgr_reports.dart';

// ---------------------------------------------------------------------------
// Stock take: the manager enters the exact stock of the main store (then transfers to bar / kitchen),
// or of the bar / kitchen. Odoo's stock is set to the count (inventory adjustment).
// ---------------------------------------------------------------------------
class StockTakeScreen extends StatefulWidget {
  const StockTakeScreen({super.key});
  @override
  State<StockTakeScreen> createState() => _StockTakeScreenState();
}

class _StockTakeScreenState extends State<StockTakeScreen> {
  List<Map<String, dynamic>> _configs = const [];
  int _config = 0;
  String _point = 'store';
  Map<String, dynamic>? _r;
  String? _error;
  String _q = '';
  bool _onlyChanged = false;
  bool _busy = false;
  final Map<int, TextEditingController> _c = {};

  @override
  void initState() {
    super.initState();
    loadConfigs().then((c) {
      if (mounted) setState(() => _configs = c);
    }).catchError((_) {});
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
    setState(() {
      _error = null;
      _r = null;
    });
    try {
      final r = await Api.call('/utange/mgr/stock_take_lines', {'config_id': _config, 'point': _point});
      if (!mounted) return;
      for (final c in _c.values) {
        c.dispose();
      }
      _c.clear();
      for (final i in ll(r['items'])) {
        _c[ii(i['product_id'])] = TextEditingController();
      }
      setState(() => _r = r);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  double? _val(Map<String, dynamic> i) => double.tryParse((_c[ii(i['product_id'])]?.text ?? '').trim());
  bool _changed(Map<String, dynamic> i) {
    final v = _val(i);
    return v != null && (v - dd(i['qty'])).abs() > 0.0001;
  }

  Future<void> _save() async {
    final items = ll(_r?['items']);
    final typed = items.where((i) => _val(i) != null).toList();
    final changed = typed.where(_changed).toList();
    if (typed.isEmpty) {
      toast(context, 'Type the counted quantity of at least one item.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save stock take?'),
        content: SingleChildScrollView(
          child: Text(changed.isEmpty
              ? 'All ${typed.length} counted items match Odoo.'
              : '${changed.length} items will be corrected in ${ss(_r?['location'])}:\n\n'
                  '${changed.take(20).map((i) => '• ${ss(i['name'])}: ${qty(dd(i['qty']))} → ${qty(_val(i)!)}').join('\n')}'
                  '${changed.length > 20 ? '\n…' : ''}\n\nItems left empty are not changed.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final r = await Api.call('/utange/mgr/stock_take_apply', {
        'config_id': _config,
        'point': _point,
        'counts': [for (final i in typed) {'product_id': ii(i['product_id']), 'qty': _val(i)}],
      });
      if (mounted) toast(context, ss(r['message']));
      await _load();
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
    final q = _q.trim().toLowerCase();
    final items = ll(r?['items'])
        .where((i) => q.isEmpty || ss(i['name']).toLowerCase().contains(q))
        .where((i) => !_onlyChanged || _changed(i))
        .toList();
    final points = ll(r?['points']);
    final typed = ll(r?['items']).where((i) => _val(i) != null).length;
    return Scaffold(
      appBar: bar('Stock take', actions: [
        IconButton(
          tooltip: 'Transfer to bar / kitchen',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TransferScreen())),
          icon: const Icon(Icons.local_shipping_rounded),
        ),
      ]),
      body: Column(children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_configs.length > 1)
              DropdownButton<int>(
                value: _config == 0 ? ii(_configs.first['id']) : _config,
                isExpanded: true,
                items: [for (final c in _configs) DropdownMenuItem(value: ii(c['id']), child: Text(ss(c['name'])))],
                onChanged: (v) {
                  setState(() => _config = v ?? 0);
                  _load();
                },
              ),
            Wrap(spacing: 8, children: [
              for (final p in points.isEmpty ? [{'point': 'store', 'label': 'Main store'}] : points)
                ChoiceChip(
                  label: Text(ss(p['label'])),
                  selected: _point == ss(p['point']),
                  onSelected: (_) {
                    setState(() => _point = ss(p['point']));
                    _load();
                  },
                ),
            ]),
            if (r != null)
              Text('${ss(r['location'])} · $typed of ${ll(r['items']).length} counted',
                  style: const TextStyle(color: C.muted, fontSize: 12.5)),
            const SizedBox(height: 6),
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
              FilterChip(label: const Text('Changed'), selected: _onlyChanged, onSelected: (v) => setState(() => _onlyChanged = v)),
            ]),
          ]),
        ),
        Expanded(
          child: Loader(
            loading: r == null,
            error: _error,
            onRetry: _load,
            child: () => items.isEmpty
                ? const EmptyNote(Icons.inventory_2_outlined, 'No stock-tracked items here.')
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 110),
                    itemCount: items.length,
                    itemBuilder: (_, n) {
                      final i = items[n];
                      final v = _val(i);
                      final diff = v == null ? null : v - dd(i['qty']);
                      final bad = diff != null && diff.abs() > 0.0001;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: v == null ? C.line : (bad ? C.amber : C.green)),
                        ),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(ss(i['name']), style: h(14, w: FontWeight.w700)),
                              Text('Odoo ${qty(dd(i['qty']))} ${ss(i['uom'])}${ss(i['categ']).isEmpty ? '' : ' · ${i['categ']}'}',
                                  style: const TextStyle(color: C.muted, fontSize: 12.5)),
                              if (bad)
                                Text('Correction ${signed(diff!)}',
                                    style: TextStyle(color: diff! < 0 ? C.red : C.amber, fontWeight: FontWeight.w700, fontSize: 12.5)),
                            ]),
                          ),
                          SizedBox(
                            width: 90,
                            child: TextField(
                              controller: _c[ii(i['product_id'])],
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              textAlign: TextAlign.center,
                              style: h(18),
                              onChanged: (_) => setState(() {}),
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
                    },
                  ),
          ),
        ),
      ]),
      bottomSheet: r == null
          ? null
          : Material(
              color: Colors.white,
              elevation: 8,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: primaryButton(typed == 0 ? 'Type the counts' : 'Save stock take ($typed)', typed == 0 ? null : _save,
                      icon: Icons.save_rounded, busy: _busy),
                ),
              ),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Transfer: main store -> bar / kitchen, done at once
// ---------------------------------------------------------------------------
class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key});
  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  List<Map<String, dynamic>> _configs = const [];
  int _config = 0;
  String _to = 'bar';
  Map<String, dynamic>? _store; // items with the main store quantities
  List<Map<String, dynamic>> _points = const [];
  String? _error;
  String _q = '';
  bool _busy = false;
  final Map<int, double> _qty = {};

  @override
  void initState() {
    super.initState();
    loadConfigs().then((c) {
      if (mounted) setState(() => _configs = c);
    }).catchError((_) {});
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _store = null;
    });
    try {
      final r = await Api.call('/utange/mgr/stock_take_lines', {'config_id': _config, 'point': 'store'});
      if (!mounted) return;
      setState(() {
        _store = r;
        _points = ll(r['points']).where((p) => ss(p['point']) != 'store').toList();
        if (_points.isNotEmpty && !_points.any((p) => ss(p['point']) == _to)) _to = ss(_points.first['point']);
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  Future<void> _setQty(Map<String, dynamic> i) async {
    final id = ii(i['product_id']);
    final c = TextEditingController(text: _qty[id] == null ? '' : qty(_qty[id]!));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ss(i['name'])),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Quantity to move (store has ${qty(dd(i['qty']))})'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim()) ?? 0), child: const Text('OK')),
        ],
      ),
    );
    if (v == null) return;
    setState(() {
      if (v <= 0) {
        _qty.remove(id);
      } else {
        _qty[id] = v;
      }
    });
  }

  Future<void> _send() async {
    final dest = _points.where((p) => ss(p['point']) == _to).map((p) => ss(p['label'])).firstOrNull ?? _to;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Move ${_qty.length} items to the $dest?'),
        content: const Text('The stock moves now (internal transfer, validated).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Move')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final r = await Api.call('/utange/mgr/transfer', {
        'config_id': _config,
        'to': _to,
        'lines': [for (final e in _qty.entries) {'product_id': e.key, 'qty': e.value}],
      });
      if (mounted) toast(context, ss(r['message']));
      _qty.clear();
      await _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
      await Store.i.handle(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _store;
    final q = _q.trim().toLowerCase();
    final items = ll(r?['items']).where((i) => q.isEmpty || ss(i['name']).toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: bar('Transfer to bar / kitchen'),
      body: Column(children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_configs.length > 1)
              DropdownButton<int>(
                value: _config == 0 ? ii(_configs.first['id']) : _config,
                isExpanded: true,
                items: [for (final c in _configs) DropdownMenuItem(value: ii(c['id']), child: Text(ss(c['name'])))],
                onChanged: (v) {
                  setState(() {
                    _config = v ?? 0;
                    _qty.clear();
                  });
                  _load();
                },
              ),
            Text('From ${ss(r?['location'])} to:', style: const TextStyle(color: C.muted)),
            Wrap(spacing: 8, children: [
              for (final p in _points)
                ChoiceChip(
                  label: Text(ss(p['label'])),
                  selected: _to == ss(p['point']),
                  onSelected: (_) => setState(() => _to = ss(p['point'])),
                ),
            ]),
            if (r != null && _points.isEmpty)
              const Text('Set the Bar / Kitchen stock locations on the Point of Sale (Odoo: Handheld settings).',
                  style: TextStyle(color: C.red, fontSize: 12.5)),
            const SizedBox(height: 6),
            TextField(
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
          ]),
        ),
        Expanded(
          child: Loader(
            loading: r == null,
            error: _error,
            onRetry: _load,
            child: () => ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 110),
              itemCount: items.length,
              itemBuilder: (_, n) {
                final i = items[n];
                final q = _qty[ii(i['product_id'])];
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: q == null ? C.line : C.green, width: q == null ? 1 : 1.5),
                  ),
                  child: ListTile(
                    title: Text(ss(i['name']), style: h(14, w: FontWeight.w700)),
                    subtitle: Text('Store has ${qty(dd(i['qty']))} ${ss(i['uom'])}'),
                    trailing: q == null ? const Icon(Icons.add_circle_outline_rounded, color: C.green) : Pill('Move ${qty(q)}'),
                    onTap: () => _setQty(i),
                  ),
                );
              },
            ),
          ),
        ),
      ]),
      bottomSheet: Material(
        color: Colors.white,
        elevation: 8,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: primaryButton(_qty.isEmpty ? 'Choose items to move' : 'Move ${_qty.length} items now',
                _qty.isEmpty || _points.isEmpty ? null : _send,
                icon: Icons.local_shipping_rounded, busy: _busy),
          ),
        ),
      ),
    );
  }
}
