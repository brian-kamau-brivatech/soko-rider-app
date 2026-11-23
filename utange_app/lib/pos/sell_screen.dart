import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api.dart';
import '../receipt.dart';
import '../store.dart';
import '../ui.dart';
import 'payment_screen.dart';
import 'count_screen.dart';
import 'shift_screen.dart';

/// Sell at the bar: items and prices come from the Odoo POS.
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
  // Order button (like Odoo): what each kitchen / bar printer already printed for this order, and its table / name
  final Map<int, Map<int, double>> _sent = {};
  String _label = '';
  bool _sending = false;
  // Tables (Odoo restaurant): pick a table first, like the Odoo floor plan; its order is kept in Odoo
  List<Map<String, dynamic>>? _floors;
  int? _floorId;
  Map<String, dynamic>? _table; // {id, name, floor}
  int? _orderId; // the open order of the table in Odoo
  String _orderUid = '';
  final Map<int, String> _uuids = {}; // product -> Odoo order line uuid
  bool _dirty = false; // changed since last saved to Odoo
  bool _direct = false; // selling without a table
  bool get _tablesOn => _setup?.tables == true;

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
      final s = PosSetup.fromJson(await Api.call('/utange/pos/setup', Store.i.base()));
      if (mounted) setState(() => _setup = s);
      if (s.tables) await _loadTables();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
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

  List<(int, double, String, List<int>)> get _cartForKitchen => [
        for (final e in _cart.entries)
          if (_p(e.key) != null) (e.key, e.value, _p(e.key)!.name, _p(e.key)!.categIds),
      ];

  /// How many items changed since the last Order (the number on the Order button, like Odoo).
  int get _unsent {
    final st = _setup;
    if (st == null || st.kitchenPrinters.isEmpty) return 0;
    final changed = <int>{};
    for (final pr in st.kitchenPrinters) {
      final before = _sent[pr.id] ?? const <int, double>{};
      for (final c in _cartForKitchen) {
        if (!(pr.categIds.isEmpty || c.$4.any(pr.categIds.contains))) continue;
        if ((c.$2 - (before[c.$1] ?? 0)).abs() > 0.0001) changed.add(c.$1);
      }
      for (final id in before.keys) {
        if (!_cart.containsKey(id) && (before[id] ?? 0) > 0.0001) changed.add(id);
      }
    }
    return changed.length;
  }

  /// Order: send the new items (and cancellations) to the kitchen / bar printers set in Odoo, before payment.
  Future<void> _order() async {
    final st = _setup;
    if (st == null) return;
    if (st.kitchenPrinters.isEmpty) {
      toast(context, 'No kitchen / bar printers in this Odoo POS (POS settings > Preparation printers).');
      return;
    }
    if (_unsent == 0) {
      toast(context, 'Nothing new to send.');
      return;
    }
    if (_table != null) _label = _tableLabel;
    if (_label.isEmpty) {
      final c = TextEditingController();
      final v = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Send order'),
          content: TextField(
            controller: c,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Table or name (optional)', hintText: 'e.g. Table 5, John'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Send')),
          ],
        ),
      );
      if (v == null || !mounted) return;
      _label = v.isEmpty ? await _nextOrderNo() : v;
    }
    setState(() => _sending = true);
    try {
      Receipt.rememberNames([for (final c in _cartForKitchen) (c.$1, c.$3)]);
      final (done, failed) = await Receipt.printKitchenChanges(
          st: st, order: _label, cashier: Store.i.cashierName, cart: _cartForKitchen, sent: _sent);
      if (_table != null) await _saveTable(quiet: false); // the order and what was sent go to Odoo (shows on the floor plan)
      if (!mounted) return;
      if (failed.isEmpty) {
        toast(context, 'Sent to ${done.join(', ')}.');
      } else {
        toast(context, '${done.isEmpty ? '' : 'Sent to ${done.join(', ')}. '}Did not answer: ${failed.join(', ')}. Check the printer, then tap Order again.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// "Order 7": a number per day on this handheld, when no table / name is given.
  Future<String> _nextOrderNo() async {
    final p = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final day = '${now.year}${now.month}${now.day}';
    final n = p.getString('order_day') == day ? (p.getInt('order_no') ?? 0) + 1 : 1;
    await p.setString('order_day', day);
    await p.setInt('order_no', n);
    return 'Order $n';
  }

  /// Empty the sale; items already sent to the kitchen / bar get a CANCELLED ticket.
  Future<void> _clear() async {
    final st = _setup;
    final wasSent = _sent.values.any((m) => m.values.any((q) => q > 0.0001));
    setState(() => _cart.clear());
    if (wasSent && st != null) {
      final (_, failed) = await Receipt.printKitchenChanges(
          st: st, order: _label, cashier: Store.i.cashierName, cart: const [], sent: _sent);
      if (mounted) toast(context, failed.isEmpty ? 'Order cancelled at the kitchen / bar.' : 'Cancel ticket not printed on: ${failed.join(', ')}.');
    }
    if (_table != null && _orderId != null) {
      await _saveTable(quiet: false); // nothing left: the open order is removed in Odoo too
    }
    _resetOrder();
    if (_table != null) _leaveTable(save: false);
  }

  void _resetOrder() {
    _sent.clear();
    _label = '';
    _orderId = null;
    _orderUid = '';
    _uuids.clear();
    _dirty = false;
  }

  // ------------------------------------------------------------------
  // Tables
  // ------------------------------------------------------------------
  String get _tableLabel => _table == null ? '' : '${_table!['floor']} · Table ${_table!['name']}';

  Future<void> _loadTables() async {
    try {
      final r = await Api.call('/utange/pos/tables', Store.i.base());
      final f = ll(r['floors']);
      if (!mounted) return;
      setState(() {
        _floors = f;
        if (f.isNotEmpty && (_floorId == null || !f.any((x) => x['id'] == _floorId))) _floorId = ii(f.first['id']);
      });
    } on ApiError catch (e) {
      await Store.i.handle(e);
    } catch (_) {}
  }

  Future<void> _openTable(Map<String, dynamic> floor, Map<String, dynamic> t) async {
    final st = _setup;
    if (st == null) return;
    if (!st.sessionOpen) {
      toast(context, 'The shift is closed. Open it first (More > Shift).');
      return;
    }
    List<Map<String, dynamic>> orders;
    try {
      orders = ll((await Api.call('/utange/pos/table_orders', Store.i.base({'table_id': t['id']})))['orders']);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
      await Store.i.handle(e);
      return;
    }
    if (!mounted) return;
    Map<String, dynamic>? pick;
    if (orders.length == 1) {
      pick = orders.first;
    } else if (orders.length > 1) {
      final choice = await showModalBottomSheet<Object>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(title: Text('Table ${t['name']}: ${orders.length} open orders', style: h(17))),
            for (final o in orders)
              ListTile(
                leading: const Icon(Icons.receipt_long_rounded),
                title: Text('${o['name']}  ·  ${ksh(dd(o['amount']))}'),
                subtitle: Text([if (ss(o['cashier']).isNotEmpty) ss(o['cashier']), '${ll(o['lines']).length} items'].join(' · ')),
                onTap: () => Navigator.pop(ctx, o),
              ),
            ListTile(leading: const Icon(Icons.add_rounded), title: const Text('New order on this table'), onTap: () => Navigator.pop(ctx, 'new')),
          ]),
        ),
      );
      if (choice == null || !mounted) return;
      if (choice is Map<String, dynamic>) pick = choice;
    }
    setState(() {
      _cart.clear();
      _resetOrder();
      _table = {'id': t['id'], 'name': t['name'], 'floor': floor['name']};
      _label = _tableLabel;
      _orderUid = 'ut-t-${DateTime.now().microsecondsSinceEpoch}';
      if (pick != null) _takeOrder(pick);
    });
  }

  /// Load an open table order from Odoo into the sale (items, and what the kitchen / bar already has).
  void _takeOrder(Map<String, dynamic> o) {
    _orderId = ii(o['id']);
    for (final l in ll(o['lines'])) {
      final pid = ii(l['product_id']);
      _cart[pid] = (_cart[pid] ?? 0) + dd(l['qty']);
      if (ss(l['uuid']).isNotEmpty) _uuids.putIfAbsent(pid, () => ss(l['uuid']));
    }
    final mine = o['sent'] is Map ? Map<String, dynamic>.from(o['sent'] as Map) : <String, dynamic>{};
    for (final e in mine.entries) {
      final items = e.value is Map ? Map<String, dynamic>.from(e.value as Map) : <String, dynamic>{};
      _sent[int.tryParse(e.key) ?? 0] = {for (final i in items.entries) int.tryParse(i.key) ?? 0: dd(i.value)};
    }
    // If the Odoo POS screen sent (or cancelled) items itself, its record wins: it is the newer one.
    final odoo = o['odoo_sent'] is Map ? Map<String, dynamic>.from(o['odoo_sent'] as Map) : <String, dynamic>{};
    final odooQty = {for (final e in odoo.entries) int.tryParse(e.key) ?? 0: dd(e.value)};
    final mineMax = <int, double>{};
    for (final m in _sent.values) {
      m.forEach((pid, q) => mineMax[pid] = (mineMax[pid] ?? 0) < q ? q : (mineMax[pid] ?? 0));
    }
    final ids = {...odooQty.keys, ...mineMax.keys};
    final differs = ids.any((pid) => ((odooQty[pid] ?? 0) - (mineMax[pid] ?? 0)).abs() > 0.0001);
    if (differs && odooQty.isNotEmpty) {
      _sent.clear();
      for (final pr in _setup?.kitchenPrinters ?? const <KitchenPrinter>[]) {
        _sent[pr.id] = {
          for (final e in odooQty.entries)
            if (pr.categIds.isEmpty || (_p(e.key)?.categIds ?? const <int>[]).any(pr.categIds.contains)) e.key: e.value,
        };
      }
    }
    _dirty = false;
  }

  /// Saves the table order in Odoo (open, unpaid), so it shows on the Odoo floor plan. Returns false on failure.
  Future<bool> _saveTable({bool quiet = true}) async {
    final t = _table;
    if (t == null) return true;
    try {
      final r = await Api.call('/utange/pos/table_save', Store.i.base({
        'table_id': t['id'],
        if (_orderId != null) 'order_id': _orderId,
        'uid': _orderUid,
        'lines': [
          for (final e in _cart.entries) {'product_id': e.key, 'qty': e.value, if (_uuids[e.key] != null) 'uuid': _uuids[e.key]}
        ],
        'sent': {
          for (final e in _sent.entries) '${e.key}': {for (final i in e.value.entries) '${i.key}': i.value}
        },
      }));
      final o = r['order'];
      if (o is Map) {
        _orderId = ii(o['id']);
        for (final l in ll(o['lines'])) {
          if (ss(l['uuid']).isNotEmpty) _uuids[ii(l['product_id'])] = ss(l['uuid']);
        }
      } else {
        _orderId = null;
      }
      _dirty = false;
      return true;
    } on ApiError catch (e) {
      if (mounted && !quiet) toast(context, 'Not saved to Odoo: ${e.message}');
      if (e.gone && mounted) {
        toast(context, e.message);
        setState(() {
          _cart.clear();
          _resetOrder();
          _table = null;
        });
        _loadTables();
      }
      await Store.i.handle(e);
      return false;
    } catch (e) {
      if (mounted && !quiet) toast(context, 'Not saved to Odoo: $e');
      return false;
    }
  }

  /// Back to the floor plan; unsaved changes are saved to Odoo first.
  Future<void> _leaveTable({bool save = true}) async {
    if (save && _dirty && _cart.isNotEmpty) {
      if (!await _saveTable(quiet: false) && mounted) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Not saved to Odoo'),
            content: const Text('The changes to this table could not be saved. Leave anyway and lose them?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave', style: TextStyle(color: C.red))),
            ],
          ),
        );
        if (go != true) return;
      }
    }
    if (!mounted) return;
    setState(() {
      _cart.clear();
      _resetOrder();
      _table = null;
      _direct = false;
    });
    _loadTables();
  }

  Widget _tablesView(PosSetup s) {
    final floors = _floors ?? const <Map<String, dynamic>>[];
    final floor = floors.where((f) => f['id'] == _floorId).firstOrNull ?? floors.firstOrNull;
    final tables = floor == null ? const <Map<String, dynamic>>[] : ll(floor['tables']);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Tables', style: h(22)),
                  Text(s.sessionOpen ? '${s.configName} · ${s.sessionName}' : '${s.configName} · shift closed',
                      style: TextStyle(fontSize: 12.5, color: s.sessionOpen ? C.muted : C.red, fontWeight: FontWeight.w600)),
                ]),
              ),
              if (Store.i.cashiersOn && Store.i.cashierName.isNotEmpty)
                ActionChip(
                  avatar: const Icon(Icons.badge_rounded, size: 18),
                  label: Text(Store.i.cashierName.split(' ').first),
                  onPressed: () => Store.i.clearCashier(),
                ),
              IconButton(tooltip: 'Refresh', onPressed: _loadTables, icon: const Icon(Icons.refresh_rounded)),
            ]),
          ),
          if (!s.sessionOpen)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: C.redLight, borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                const Expanded(child: Text('The shift is closed. Count the stock to open it.', style: TextStyle(color: C.red, fontWeight: FontWeight.w600))),
                TextButton(
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShiftScreen()));
                    _load();
                  },
                  child: const Text('Open shift'),
                ),
              ]),
            ),
          SizedBox(
            height: 48,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(16, 6, 16, 0), children: [
              for (final f in floors) _chip('${f['name']}', f['id'] == floor?['id'], () => setState(() => _floorId = ii(f['id']))),
            ]),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _floors == null
                ? const Center(child: CircularProgressIndicator(color: C.green))
                : tables.isEmpty
                    ? const EmptyNote(Icons.table_restaurant_rounded, 'No tables on this floor. Add them in the Odoo POS floor plan.')
                    : RefreshIndicator(
                        color: C.green,
                        onRefresh: _loadTables,
                        child: GridView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 130, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1),
                          itemCount: tables.length,
                          itemBuilder: (_, i) {
                            final t = tables[i];
                            final busy = ii(t['orders']) > 0;
                            return Material(
                              color: busy ? const Color(0xFF6BCF7F) : const Color(0xFFD1D5DB),
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _openTable(floor!, t),
                                child: Stack(children: [
                                  Center(
                                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                                      Text('${t['name']}', style: h(24, color: busy ? Colors.white : C.ink)),
                                      const SizedBox(height: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(6)),
                                        child: Text(busy ? '${ii(t['guests'])}/${ii(t['seats'])}' : '${ii(t['seats'])}',
                                            style: h(13, color: Colors.white)),
                                      ),
                                      if (busy)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 4),
                                          child: Text(ksh(dd(t['amount'])), style: h(12, color: Colors.white)),
                                        ),
                                    ]),
                                  ),
                                  if (ii(t['orders']) > 0)
                                    Positioned(
                                      right: 6,
                                      top: 6,
                                      child: CircleAvatar(
                                        radius: 11,
                                        backgroundColor: C.red,
                                        child: Text('${ii(t['orders'])}', style: h(12, color: Colors.white)),
                                      ),
                                    ),
                                ]),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ]),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: s.sessionOpen ? () => setState(() => _direct = true) : null,
        backgroundColor: C.navy,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.shopping_bag_rounded),
        label: const Text('Direct sale'),
      ),
    );
  }

  double get _total => _cart.entries.fold<double>(0, (a, e) => a + (_p(e.key)?.price ?? 0) * e.value);
  double get _count => _cart.values.fold<double>(0, (a, q) => a + q);

  /// No selling more than the bar / kitchen has (when Odoo says so).
  bool _tooMuch(PosProduct p, double q) {
    final s = _setup;
    if (s == null || !s.blockZero || p.qty == null || q <= p.qty! + 0.0001) return false;
    final where = p.point == 'bar' ? 'the bar' : p.point == 'kitchen' ? 'the kitchen' : 'stock';
    toast(context, p.qty! <= 0
        ? '${p.name}: none left in $where. Make a requisition (Requests tab).'
        : '${p.name}: only ${_qtyText(p.qty!)} left in $where.');
    return true;
  }

  void _add(PosProduct p, [double by = 1]) {
    if (by > 0 && _tooMuch(p, (_cart[p.id] ?? 0) + by)) return;
    setState(() {
      _dirty = true;
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
    if (_tooMuch(p, v)) return;
    setState(() {
      _dirty = true;
      if (v == 0) {
        _cart.remove(p.id);
      } else {
        _cart[p.id] = v;
      }
    });
  }

  String _qtyText(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  /// The shift was opened in Odoo: count and confirm the opening stock before selling.
  Future<void> _confirmOpening() async {
    final counts = await Navigator.of(context)
        .push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => const CountScreen(phase: 'open')));
    if (counts == null || !mounted) return;
    try {
      final r = await Api.call('/utange/pos/sheet_confirm_open', Store.i.base(counts));
      if (mounted) toast(context, ss(r['message']));
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
      await Store.i.handle(e);
    }
    _load();
  }

  Future<void> _charge() async {
    // Fresh payment methods and session state from Odoo POS on every charge.
    try {
      final fresh = PosSetup.fromJson(await Api.call('/utange/pos/setup', Store.i.base()));
      if (mounted) setState(() => _setup = fresh);
    } catch (_) {}
    if (!mounted) return;
    final s = _setup!;
    if (s.methods.isEmpty) {
      toast(context, 'This POS has no payment methods. Add them in Odoo POS settings.');
      return;
    }
    if (!s.sessionOpen) {
      toast(context, 'The shift is closed. Open it first (More > Shift).');
      return;
    }
    if (s.needsOpenCount) {
      await _confirmOpening();
      return;
    }
    if (_table != null && (_dirty || _orderId == null)) {
      if (!await _saveTable(quiet: false)) return; // the table order must be in Odoo before it is paid
      if (!mounted) return;
    }
    final sold = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PaymentScreen(
        setup: s,
        lines: [
          for (final e in _cart.entries)
            if (_p(e.key) != null) CartLine(_p(e.key)!, e.value),
        ],
        sent: _sent,
        label: _label,
        orderId: _table != null ? _orderId : null,
      ),
    ));
    if (sold == true && mounted) {
      setState(() {
        _cart.clear();
        _resetOrder();
        _table = null;
        _direct = false;
      });
      _load(); // fresh stock numbers (and tables)
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
                        Navigator.pop(ctx);
                        _clear();
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
                if ((_setup?.kitchenPrinters ?? const []).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: OutlinedButton.icon(
                        onPressed: _cart.isEmpty && _unsent == 0
                            ? null
                            : () async {
                                await _order();
                                setSheet(() {});
                              },
                        icon: const Icon(Icons.restaurant_rounded),
                        label: Text(_unsent > 0 ? 'Order ($_unsent new)${_label.isEmpty ? '' : ' · $_label'}' : 'Order sent${_label.isEmpty ? '' : ' · $_label'}',
                            style: h(16)),
                      ),
                    ),
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
  Widget build(BuildContext context) {
    final s = _setup;
    if (s != null && _tablesOn && _table == null && !_direct) return _tablesView(s);
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
              if (_tablesOn)
                IconButton(
                  tooltip: 'Tables',
                  onPressed: () => _leaveTable(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_table != null ? 'Table ${_table!['name']}' : (_tablesOn ? 'Direct sale' : 'Sell'), style: h(22)),
                  if (_table != null)
                    Text('${_table!['floor']}${_orderId == null ? ' · new order' : ''}${_dirty ? ' · not saved yet' : ''}',
                        style: const TextStyle(fontSize: 12.5, color: C.muted, fontWeight: FontWeight.w600))
                  else if (s != null)
                    Text(s.sessionOpen ? '${s.configName} · ${s.sessionName}' : '${s.configName} · shift closed',
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
          if (s != null && s.sessionOpen && s.needsOpenCount)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
              decoration: BoxDecoration(color: C.amberLight, borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                const Icon(Icons.fact_check_rounded, color: C.amber),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('This shift was opened in Odoo. Confirm the opening stock before selling.',
                      style: TextStyle(color: C.amber, fontWeight: FontWeight.w700)),
                ),
                TextButton(onPressed: _confirmOpening, child: const Text('Count now')),
              ]),
            ),
          if (s != null && !s.sessionOpen)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: C.redLight, borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                const Expanded(
                  child: Text('The shift is closed. Count the stock to open it.', style: TextStyle(color: C.red, fontWeight: FontWeight.w600)),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShiftScreen()));
                    _load();
                  },
                  icon: const Icon(Icons.lock_open_rounded),
                  label: const Text('Open shift'),
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
                hintText: 'Search item or scan barcode',
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
                    ? const EmptyNote(Icons.inventory_2_outlined, 'No items. In Odoo, tick "Available in POS" on products.')
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
                      if ((_setup?.kitchenPrinters ?? const []).isNotEmpty) ...[
                        OutlinedButton.icon(
                          onPressed: _sending ? null : _order,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(color: _unsent > 0 ? C.gold : Colors.white54, width: _unsent > 0 ? 2 : 1),
                          ),
                          icon: const Icon(Icons.restaurant_rounded, size: 18),
                          label: Text(_sending ? '...' : (_unsent > 0 ? 'Order $_unsent' : 'Sent'), style: h(14, color: Colors.white)),
                        ),
                        const SizedBox(width: 8),
                      ],
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
