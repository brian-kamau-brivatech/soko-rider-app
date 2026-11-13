import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'shell.dart';

/// Requisitions: the bar asks the main store for items; the manager approves.
class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});
  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  List<Requisition>? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    posTab.addListener(_onTab);
  }

  @override
  void dispose() {
    posTab.removeListener(_onTab);
    super.dispose();
  }

  void _onTab() {
    if (posTab.value == 2) _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.call('/utange/pos/requisitions', Store.i.base());
      if (mounted) {
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

  Future<void> _new() async {
    final made = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const NewRequestScreen()));
    if (made == true) _load();
  }

  Future<void> _cancel(Requisition r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cancel ${r.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Cancel request')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await Api.call('/utange/pos/requisition_cancel', Store.i.base({'requisition_id': r.id}));
      if (mounted) toast(context, ss(res['message']));
      _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
      await Store.i.handle(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _new,
        backgroundColor: C.green,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New request'),
      ),
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: C.green,
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 100), children: [
            Text('Requests to the store', style: h(22)),
            const SizedBox(height: 4),
            const Text('Ask the main store for items. The manager approves, then the store issues them.',
                style: TextStyle(color: C.muted)),
            const SizedBox(height: 12),
            if (list == null && _error == null)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: C.green)))
            else if (list == null)
              EmptyNote(Icons.wifi_off_rounded, _error!)
            else if (list.isEmpty)
              const EmptyNote(Icons.assignment_outlined, 'No requests yet. Tap New request.')
            else
              for (final r in list) _card(r),
          ]),
        ),
      ),
    );
  }

  Widget _card(Requisition r) {
    final (fg, bg) = reqColors(r.state);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(r.name, style: h(15))),
          Pill(r.stateLabel, fg: fg, bg: bg),
        ]),
        Text('${r.date}${r.by.isEmpty ? '' : ' · ${r.by}'} · from ${r.from}', style: const TextStyle(color: C.muted, fontSize: 12.5)),
        const SizedBox(height: 8),
        for (final l in r.lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Expanded(child: Text(ss(l['name']))),
              Text(r.state == 'done' ? '${qty(dd(l['issued']))} of ${qty(dd(l['qty']))}' : qty(dd(l['qty'])), style: h(14)),
            ]),
          ),
        if (r.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Note: ${r.note}')),
        if (r.managerNote.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text('Manager: ${r.managerNote}', style: const TextStyle(color: C.navy))),
        if (r.state == 'submitted')
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => _cancel(r), child: const Text('Cancel', style: TextStyle(color: C.red))),
          ),
      ]),
    );
  }
}

class NewRequestScreen extends StatefulWidget {
  const NewRequestScreen({super.key});
  @override
  State<NewRequestScreen> createState() => _NewRequestScreenState();
}

class _NewRequestScreenState extends State<NewRequestScreen> {
  List<Map<String, dynamic>>? _products;
  String _bar = '';
  String _store = '';
  String? _error;
  String _q = '';
  final Map<int, double> _cart = {};
  final _note = TextEditingController();
  final String _uid = 'rq-${DateTime.now().microsecondsSinceEpoch}';
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await Api.call('/utange/pos/stock', Store.i.base());
      if (mounted) {
        setState(() {
          _products = ll(r['products']);
          _bar = ss(r['bar']);
          _store = ss(r['store']);
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  String _name(int id) => ss((_products ?? const []).firstWhere((p) => ii(p['id']) == id, orElse: () => const {})['name']);

  Future<void> _ask(Map<String, dynamic> p) async {
    final c = TextEditingController(text: _cart.containsKey(ii(p['id'])) ? qty(_cart[ii(p['id'])]!) : '');
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ss(p['name'])),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('In the bar: ${qty(dd(p['bar']))}${p['store'] != null ? ' · in the store: ${qty(dd(p['store']))}' : ''}',
              style: const TextStyle(color: C.muted)),
          TextField(
            controller: c,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: 'Quantity to ask for (${ss(p['uom'])})'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 0.0), child: const Text('Remove')),
          FilledButton(onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim()) ?? 0), child: const Text('OK')),
        ],
      ),
    );
    if (v == null) return;
    setState(() {
      if (v <= 0) {
        _cart.remove(ii(p['id']));
      } else {
        _cart[ii(p['id'])] = v;
      }
    });
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      final r = await Api.call('/utange/pos/requisition_create', Store.i.base({
        'uid': _uid,
        'note': _note.text.trim(),
        'lines': [for (final e in _cart.entries) {'product_id': e.key, 'qty': e.value}],
      }));
      if (!mounted) return;
      toast(context, ss(r['message']));
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
      await Store.i.handle(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = (_products ?? const <Map<String, dynamic>>[]).where((p) => q.isEmpty || ss(p['name']).toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: bar('New request'),
      body: Loader(
        loading: _products == null,
        error: _error,
        onRetry: _load,
        child: () => ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 120), children: [
          Text('From $_store to $_bar', style: const TextStyle(color: C.muted)),
          const SizedBox(height: 10),
          if (_cart.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(color: C.greenLight, borderRadius: BorderRadius.circular(14)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Asking for ${_cart.length} items', style: h(15, color: C.greenDark)),
                for (final e in _cart.entries)
                  Row(children: [Expanded(child: Text(_name(e.key))), Text(qty(e.value), style: h(14))]),
                TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note for the manager (optional)')),
              ]),
            ),
          TextField(
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
          const SizedBox(height: 8),
          for (final p in list)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _cart.containsKey(ii(p['id'])) ? C.green : C.line),
              ),
              child: ListTile(
                title: Text(ss(p['name']), style: h(14, w: FontWeight.w700)),
                subtitle: Text('Bar ${qty(dd(p['bar']))}${p['store'] != null ? ' · Store ${qty(dd(p['store']))}' : ''}'),
                trailing: _cart.containsKey(ii(p['id']))
                    ? Pill(qty(_cart[ii(p['id'])]!))
                    : const Icon(Icons.add_circle_outline_rounded, color: C.green),
                onTap: () => _ask(p),
              ),
            ),
        ]),
      ),
      bottomSheet: _cart.isEmpty
          ? null
          : Material(
              color: Colors.white,
              elevation: 8,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: primaryButton('Send to manager (${_cart.length})', _send, icon: Icons.send_rounded, busy: _sending),
                ),
              ),
            ),
    );
  }
}
