import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'payment.dart';
import 'cashier_screen.dart';
import 'session_screen.dart';

/// Sell at the counter: products and prices come from the Odoo POS.
class SellScreen extends StatefulWidget {
  const SellScreen({super.key});
  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  PosSetup? _setup;
  String? _error;
  bool _loading = false;
  final _search = TextEditingController();
  String _q = '';
  int? _cat;
  final Map<int, double> _cart = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await PosApi.setup(Store.i.pin);
      if (mounted) setState(() => _setup = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  PosProduct? _p(int id) {
    for (final p in _setup?.products ?? const <PosProduct>[]) {
      if (p.id == id) return p;
    }
    return null;
  }

  double get _total => _cart.entries.fold<double>(0, (a, e) => a + (_p(e.key)?.price ?? 0) * e.value);
  double get _count => _cart.values.fold<double>(0, (a, q) => a + q);

  void _add(PosProduct p, [double by = 1]) {
    setState(() {
      final q = (_cart[p.id] ?? 0) + by;
      if (q <= 0) {
        _cart.remove(p.id);
      } else {
        _cart[p.id] = q;
      }
    });
  }

  Future<void> _setQty(PosProduct p) async {
    final c = TextEditingController(text: _qtyText(_cart[p.id] ?? 1));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.name),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Quantity${p.uom.isEmpty ? '' : ' (${p.uom})'}'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim()) ?? -1), child: const Text('OK')),
        ],
      ),
    );
    if (v == null || v < 0) return;
    setState(() {
      if (v == 0) {
        _cart.remove(p.id);
      } else {
        _cart[p.id] = v;
      }
    });
  }

  String _qtyText(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  Future<void> _charge() async {
    if (!await ensureCashier(context) || !mounted) return;
    // Fresh payment methods and session state from Odoo POS on every charge.
    try {
      final fresh = await PosApi.setup(Store.i.pin);
      if (mounted) setState(() => _setup = fresh);
    } catch (_) {}
    if (!mounted) return;
    final s = _setup!;
    if (s.methods.isEmpty) {
      toast(context, 'This POS has no payment methods. Add them in Odoo POS settings.');
      return;
    }
    if (!s.sessionOpen) {
      toast(context, 'Open the POS session in Odoo first.');
      return;
    }
    final sold = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PaymentScreen(
        setup: s,
        lines: [
          for (final e in _cart.entries)
            if (_p(e.key) != null) CartLine(_p(e.key)!, e.value),
        ],
      ),
    ));
    if (sold == true && mounted) {
      setState(() => _cart.clear());
      _load(); // fresh stock numbers
    }
  }

  void _openCart() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final ids = _cart.keys.toList();
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
                  child: Row(children: [
                    Expanded(child: Text('Current sale', style: h(18))),
                    TextButton(
                      onPressed: () {
                        setState(() => _cart.clear());
                        Navigator.pop(ctx);
                      },
                      child: const Text('Clear', style: TextStyle(color: C.red)),
                    ),
                  ]),
                ),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final id in ids)
                      if (_p(id) != null)
                        ListTile(
                          title: Text(_p(id)!.name, style: h(14.5, w: FontWeight.w700)),
                          subtitle: Text('${ksh(_p(id)!.price)} × ${_qtyText(_cart[id] ?? 0)}'),
                          onTap: () async {
                            await _setQty(_p(id)!);
                            setSheet(() {});
                          },
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              tooltip: 'One less',
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: () {
                                _add(_p(id)!, -1);
                                setSheet(() {});
                                if (_cart.isEmpty) Navigator.pop(ctx);
                              },
                            ),
                            Text(_qtyText(_cart[id] ?? 0), style: h(15)),
                            IconButton(
                              tooltip: 'One more',
                              icon: const Icon(Icons.add_circle, color: C.green),
                              onPressed: () {
                                _add(_p(id)!);
                                setSheet(() {});
                              },
                            ),
                          ]),
                        ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: _cart.isEmpty
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              _charge();
                            },
                      style: ElevatedButton.styleFrom(backgroundColor: C.green, foregroundColor: Colors.white),
                      child: Text('Charge ${ksh(_total)}', style: h(17, color: Colors.white)),
                    ),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Store.i,
        builder: (context, _) => Store.i.needsCashier ? const CashierScreen() : _sellBody(context),
      );

  Widget _sellBody(BuildContext context) {
    final s = _setup;
    final q = _q.trim().toLowerCase();
    final products = (s?.products ?? const <PosProduct>[])
        .where((p) => _cat == null || p.categIds.contains(_cat))
        .where((p) => q.isEmpty || p.name.toLowerCase().contains(q) || p.barcode == q)
        .toList();
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Sell', style: h(22)),
                  if (s != null)
                    Text(s.sessionOpen ? '${s.configName} · ${s.sessionName} · ${s.cashier}' : '${s.configName} · session closed',
                        style: TextStyle(fontSize: 12.5, color: s.sessionOpen ? C.muted : C.red, fontWeight: FontWeight.w600)),
                ]),
              ),
              if (Store.i.cashiersOn && Store.i.cashierName.isNotEmpty)
                ActionChip(
                  avatar: const Icon(Icons.badge_rounded, size: 18),
                  label: Text(Store.i.cashierName.split(' ').first),
                  tooltip: 'Switch cashier',
                  onPressed: () => Store.i.clearCashier(),
                ),
              IconButton(tooltip: 'Reload products', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh_rounded)),
            ]),
          ),
          if (s != null && !s.sessionOpen)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: C.redLight, borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                const Expanded(
                  child: Text('The POS session is closed.', style: TextStyle(color: C.red, fontWeight: FontWeight.w600)),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SessionScreen()));
                    _load();
                  },
                  icon: const Icon(Icons.lock_open_rounded),
                  label: const Text('Open session'),
                  style: TextButton.styleFrom(foregroundColor: C.red),
                ),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: 'Search product or scan barcode',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: Colors.white,
                isDense: true,
                suffixIcon: _q.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() {
                          _search.clear();
                          _q = '';
                        }),
                      ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
              ),
            ),
          ),
          if ((s?.categories ?? const []).isNotEmpty)
            SizedBox(
              height: 46,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), children: [
                _chip('All', _cat == null, () => setState(() => _cat = null)),
                for (final c in s!.categories) _chip('${c['name']}', _cat == c['id'], () => setState(() => _cat = c['id'] as int)),
              ]),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: s == null
                ? (_error != null
                    ? Column(children: [EmptyNote(Icons.wifi_off_rounded, _error!), TextButton(onPressed: _load, child: const Text('Try again'))])
                    : const Center(child: CircularProgressIndicator(color: C.green)))
                : products.isEmpty
                    ? const EmptyNote(Icons.inventory_2_outlined, 'No products. In Odoo, tick "Available in POS" on products.')
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 170,
                          mainAxisExtent: 168,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: products.length,
                        itemBuilder: (_, i) => _ProductTile(
                          p: products[i],
                          qty: _cart[products[i].id] ?? 0,
                          onTap: s.sessionOpen ? () => _add(products[i]) : null,
                          onLongPress: s.sessionOpen ? () => _setQty(products[i]) : null,
                        ),
                      ),
          ),
        ]),
      ),
      bottomSheet: _cart.isEmpty
          ? null
          : Material(
              color: C.navy,
              child: SafeArea(
                top: false,
                child: InkWell(
                  onTap: _openCart,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
                    child: Row(children: [
                      const Icon(Icons.shopping_basket_rounded, color: Colors.white),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('${_qtyText(_count)} items · ${ksh(_total)}', style: h(16, color: Colors.white)),
                      ),
                      ElevatedButton(
                        onPressed: _charge,
                        style: ElevatedButton.styleFrom(backgroundColor: C.green, foregroundColor: Colors.white),
                        child: Text('Charge', style: h(15, color: Colors.white)),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback tap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: on,
          onSelected: (_) => tap(),
          selectedColor: C.navy,
          showCheckmark: false,
          labelStyle: h(13, w: FontWeight.w700, color: on ? Colors.white : C.ink),
          backgroundColor: Colors.white,
          side: BorderSide(color: on ? C.navy : C.line),
        ),
      );
}

class _ProductTile extends StatelessWidget {
  final PosProduct p;
  final double qty;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const _ProductTile({required this.p, required this.qty, this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final low = p.qty != null && p.qty! <= 0;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: qty > 0 ? C.green : C.line, width: qty > 0 ? 2 : 1),
          ),
          padding: const EdgeInsets.all(8),
          child: Stack(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Center(
                  child: Image.network(p.image, fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined, color: C.muted, size: 34)),
                ),
              ),
              const SizedBox(height: 4),
              Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: h(13, w: FontWeight.w700)),
              Row(children: [
                Expanded(child: Text(ksh(p.price), style: h(13.5, color: C.green))),
                if (p.qty != null)
                  Text('${p.qty!.toStringAsFixed(p.qty! == p.qty!.roundToDouble() ? 0 : 1)} left',
                      style: TextStyle(fontSize: 11, color: low ? C.red : C.muted, fontWeight: FontWeight.w600)),
              ]),
            ]),
            if (qty > 0)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: C.green, borderRadius: BorderRadius.circular(999)),
                  child: Text(qty == qty.roundToDouble() ? qty.toStringAsFixed(0) : qty.toStringAsFixed(1),
                      style: h(12, color: Colors.white)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
