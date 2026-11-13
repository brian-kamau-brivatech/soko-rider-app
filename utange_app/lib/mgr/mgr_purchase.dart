import 'dart:async';
import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'mgr_shell.dart';

/// Purchases: buy from a supplier and receive into the main store.
class MgrPurchases extends StatefulWidget {
  const MgrPurchases({super.key});
  @override
  State<MgrPurchases> createState() => _MgrPurchasesState();
}

class _MgrPurchasesState extends State<MgrPurchases> {
  List<Map<String, dynamic>>? _list;
  bool _po = true;
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
    if (mgrTab.value == 4) _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.call('/utange/mgr/purchases', {});
      if (mounted) {
        setState(() {
          _list = ll(r['purchases']);
          _po = r['purchase'] == true;
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
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const NewPurchase()));
          if (ok == true) _load();
        },
        backgroundColor: C.green,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_shopping_cart_rounded),
        label: const Text('New purchase'),
      ),
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: C.green,
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 100), children: [
            Text('Purchases', style: h(22)),
            Text(_po ? 'Purchase orders, received into the main store' : 'Stock received into the main store',
                style: const TextStyle(color: C.muted)),
            const SizedBox(height: 12),
            if (list == null && _error == null)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: C.green)))
            else if (list == null)
              EmptyNote(Icons.wifi_off_rounded, _error!)
            else if (list.isEmpty)
              const EmptyNote(Icons.shopping_cart_outlined, 'No purchases yet.')
            else
              for (final p in list)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: card(14),
                  child: ListTile(
                    title: Text('${ss(p['ref'])} · ${ss(p['vendor'])}', style: h(14.5, w: FontWeight.w700)),
                    subtitle: Text('${ss(p['date'])} · ${ii(p['items'])} items · ${ss(p['state'])}'),
                    trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(ksh(dd(p['total'])), style: h(14)),
                      p['received'] == true
                          ? const Pill('Received')
                          : const Pill('Not received', fg: C.amber, bg: C.amberLight),
                    ]),
                  ),
                ),
          ]),
        ),
      ),
    );
  }
}

class NewPurchase extends StatefulWidget {
  const NewPurchase({super.key});
  @override
  State<NewPurchase> createState() => _NewPurchaseState();
}

class _PLine {
  final int id;
  final String name;
  final TextEditingController qty;
  final TextEditingController price;
  _PLine(this.id, this.name, double cost)
      : qty = TextEditingController(text: '1'),
        price = TextEditingController(text: cost > 0 ? qty_(cost) : '');
  static String qty_(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}

class _NewPurchaseState extends State<NewPurchase> {
  final _vendorQ = TextEditingController();
  final _ref = TextEditingController();
  final _itemQ = TextEditingController();
  List<Map<String, dynamic>> _vendors = const [];
  List<Map<String, dynamic>> _found = const [];
  int? _vendorId;
  String _vendorName = '';
  final List<_PLine> _lines = [];
  bool _receive = true;
  bool _saving = false;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _searchVendors('');
  }

  @override
  void dispose() {
    _t?.cancel();
    _vendorQ.dispose();
    _ref.dispose();
    _itemQ.dispose();
    for (final l in _lines) {
      l.qty.dispose();
      l.price.dispose();
    }
    super.dispose();
  }

  Future<void> _searchVendors(String q) async {
    try {
      final r = await Api.call('/utange/mgr/vendors', {'q': q});
      if (mounted) setState(() => _vendors = ll(r['vendors']));
    } catch (_) {}
  }

  void _searchItems(String q) {
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: 400), () async {
      if (q.trim().length < 2) {
        if (mounted) setState(() => _found = const []);
        return;
      }
      try {
        final r = await Api.call('/utange/mgr/products', {'q': q.trim(), 'only_pos': false});
        if (mounted) setState(() => _found = ll(r['products']).take(12).toList());
      } catch (_) {}
    });
  }

  double get _total => _lines.fold<double>(
      0, (a, l) => a + (double.tryParse(l.qty.text.trim()) ?? 0) * (double.tryParse(l.price.text.trim()) ?? 0));

  Future<void> _save() async {
    if (_vendorId == null && _vendorQ.text.trim().isEmpty) {
      toast(context, 'Choose or type the supplier.');
      return;
    }
    if (_lines.isEmpty) {
      toast(context, 'Add at least one item.');
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await Api.call('/utange/mgr/purchase_create', {
        if (_vendorId != null) 'vendor_id': _vendorId,
        if (_vendorId == null) 'vendor_name': _vendorQ.text.trim(),
        'ref': _ref.text.trim(),
        'receive': _receive,
        'lines': [
          for (final l in _lines)
            {'product_id': l.id, 'qty': double.tryParse(l.qty.text.trim()) ?? 0, 'price': double.tryParse(l.price.text.trim()) ?? 0}
        ],
      });
      if (!mounted) return;
      toast(context, ss(r['message']));
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
      await Store.i.handle(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: bar('New purchase'),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 30), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: card(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Supplier', style: h(15)),
            if (_vendorId != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.check_circle_rounded, color: C.green),
                title: Text(_vendorName, style: h(15, w: FontWeight.w700)),
                trailing: TextButton(onPressed: () => setState(() => _vendorId = null), child: const Text('Change')),
              )
            else ...[
              TextField(
                controller: _vendorQ,
                onChanged: _searchVendors,
                decoration: const InputDecoration(labelText: 'Search or type a new supplier', prefixIcon: Icon(Icons.store_rounded)),
              ),
              for (final v in _vendors.take(6))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(ss(v['name'])),
                  subtitle: ss(v['phone']).isEmpty ? null : Text(ss(v['phone'])),
                  onTap: () => setState(() {
                    _vendorId = ii(v['id']);
                    _vendorName = ss(v['name']);
                  }),
                ),
            ],
            TextField(controller: _ref, decoration: const InputDecoration(labelText: 'Supplier invoice / delivery no. (optional)')),
          ]),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: card(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Items', style: h(15)),
            for (var n = 0; n < _lines.length; n++)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Expanded(child: Text(_lines[n].name, style: const TextStyle(fontWeight: FontWeight.w700))),
                  SizedBox(
                    width: 62,
                    child: TextField(
                      controller: _lines[n].qty,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Qty', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 84,
                    child: TextField(
                      controller: _lines[n].price,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Unit cost', isDense: true),
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _lines.removeAt(n)),
                    icon: const Icon(Icons.close_rounded, color: C.red),
                  ),
                ]),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _itemQ,
              onChanged: _searchItems,
              decoration: const InputDecoration(labelText: 'Add item: search', prefixIcon: Icon(Icons.add_rounded)),
            ),
            for (final p in _found)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(ss(p['name'])),
                subtitle: Text(p['store_qty'] != null ? 'Main store ${qty(dd(p['store_qty']))}' : ''),
                onTap: () => setState(() {
                  _lines.add(_PLine(ii(p['id']), ss(p['name']), dd(p['cost'])));
                  _found = const [];
                  _itemQ.clear();
                }),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: card(),
          child: SwitchListTile(
            title: const Text('Received now'),
            subtitle: const Text('The goods are in: add them to the main store stock now'),
            value: _receive,
            onChanged: (v) => setState(() => _receive = v),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [Expanded(child: Text('Total (before tax)', style: h(15))), Text(ksh(_total), style: h(18))]),
        const SizedBox(height: 16),
        primaryButton(_receive ? 'Buy and receive' : 'Confirm purchase', _save, icon: Icons.shopping_cart_checkout_rounded, busy: _saving),
      ]),
    );
  }
}
