import 'package:flutter/material.dart';
import '../bus.dart';
import '../db.dart';
import '../fmt.dart';
import '../ops.dart';
import '../perms.dart';
import '../sales.dart' show SaleError;
import '../session.dart';
import '../stock.dart';
import '../ui.dart';
import 'purchases_screen.dart';
import 'shell.dart';

class StockHome extends StatefulWidget {
  const StockHome({super.key});
  @override
  State<StockHome> createState() => _StockHomeState();
}

class _StockHomeState extends State<StockHome> {
  int _low = 0, _pending = 0, _drafts = 0;
  double _value = 0;

  @override
  void initState() {
    super.initState();
    dataSettled.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataSettled.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final low = await Db.count('SELECT COUNT(*) FROM products p WHERE p.active = 1 AND p.track = 1 AND '
        '(SELECT COALESCE(SUM(qty),0) FROM stock WHERE product_id = p.id) <= p.reorder');
    final pending = await Db.count("SELECT COUNT(*) FROM requisitions WHERE state = 'pending'");
    final drafts = await Db.count("SELECT COUNT(*) FROM purchases WHERE state = 'draft'");
    final value = await Db.sum('SELECT COALESCE(SUM(s.qty * p.cost),0) FROM stock s JOIN products p ON p.id = s.product_id WHERE s.qty > 0');
    if (mounted) setState(() { _low = low; _pending = pending; _drafts = drafts; _value = value; });
  }

  void _go(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    final ses = Session.i;
    Widget tile(IconData icon, String title, String sub, Widget page, {int badge = 0}) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: box(),
          child: ListTile(
            leading: CircleAvatar(backgroundColor: C.soft, child: Icon(icon, color: C.ink)),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(sub),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (badge > 0) Pill('$badge', fg: Colors.white, bg: C.gold),
              const Icon(Icons.chevron_right),
            ]),
            onTap: () => _go(page),
          ),
        );
    return Scaffold(
      appBar: const TopBar('Stock'),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        Row(children: [
          Expanded(child: StatTile(dark: true, value: short(_value), label: 'Stock value (KSh)', progress: 1, note: 'at cost')),
          const SizedBox(width: 12),
          Expanded(child: StatTile(value: '$_low', label: 'Low on stock', progress: _low > 0 ? 1 : 0, note: 'reorder', bar: C.pink, onTap: () => _go(const StockList(lowOnly: true)))),
        ]),
        const SizedBox(height: 16),
        tile(Icons.inventory_2_outlined, 'Stock on hand', 'Quantities per location', const StockList()),
        if (ses.can(P.products)) tile(Icons.sell_outlined, 'Products', 'Add items, prices, VAT, barcodes', const ProductsScreen()),
        if (ses.can(P.stockAdjust)) tile(Icons.fact_check_outlined, 'Stock count', 'Count a location and correct the stock', const StockCountScreen()),
        if (ses.can(P.reqCreate) || ses.can(P.reqApprove))
          tile(Icons.move_up_rounded, 'Requisitions', 'Ask the store for stock, approve transfers', const RequisitionsScreen(), badge: _pending),
        if (ses.can(P.purchase) || ses.can(P.purchaseReceive) || ses.can(P.supplierPay))
          tile(Icons.local_shipping_outlined, 'Purchases', 'Orders to suppliers, receive stock', const PurchasesScreen(), badge: _drafts),
        if (ses.can(P.purchase)) tile(Icons.storefront_outlined, 'Suppliers', 'Who you buy from, what you owe', const SuppliersScreen()),
        tile(Icons.swap_vert_rounded, 'Stock movements', 'Every item in and out', const MovesScreen()),
        if (ses.can(P.products)) tile(Icons.category_outlined, 'Categories', 'Groups on the Sell screen', const CategoriesScreen()),
        if (ses.can(P.settings) || ses.can(P.stockAdjust)) tile(Icons.warehouse_outlined, 'Locations', 'Main store, shop, bar, kitchen...', const LocationsScreen()),
      ]),
    );
  }
}

Future<List<Map<String, Object?>>> locations() => Db.q("SELECT * FROM locations WHERE active = 1 ORDER BY kind = 'store' DESC, name");

class StockList extends StatefulWidget {
  final bool lowOnly;
  const StockList({super.key, this.lowOnly = false});
  @override
  State<StockList> createState() => _StockListState();
}

class _StockListState extends State<StockList> {
  List<Map<String, Object?>> _locs = [];
  int _loc = 0;
  String _q = '';
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    dataSettled.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataSettled.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final l = await locations();
    var r = await Stock.list(locationId: _loc, search: _q);
    if (widget.lowOnly) {
      final all = await Stock.list(search: _q);
      final lowIds = all.where((p) => d(p['on_hand']) <= d(p['reorder'])).map((p) => n(p['id'])).toSet();
      r = r.where((p) => lowIds.contains(n(p['id']))).toList();
    }
    if (mounted) setState(() { _locs = l; _rows = r; });
  }

  @override
  Widget build(BuildContext context) {
    final value = _rows.fold<double>(0, (a, p) => a + (d(p['on_hand']) > 0 ? d(p['on_hand']) * d(p['cost']) : 0));
    return Scaffold(
      appBar: AppBar(title: Text(widget.lowOnly ? 'Low on stock' : 'Stock on hand')),
      body: Column(children: [
        SizedBox(
          height: 46,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final o in [<String, Object?>{'id': 0, 'name': 'All locations'}, ..._locs])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  label: Text(s(o['name'])),
                  selected: _loc == n(o['id']),
                  showCheckmark: false,
                  selectedColor: C.ink,
                  labelStyle: TextStyle(color: _loc == n(o['id']) ? Colors.white : C.text, fontWeight: FontWeight.w700),
                  onSelected: (_) { setState(() => _loc = n(o['id'])); _load(); },
                ),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: TextField(decoration: const InputDecoration(hintText: 'Search', prefixIcon: Icon(Icons.search)), onChanged: (v) { _q = v; _load(); }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Row(children: [Text('${_rows.length} items', style: muted), const Spacer(), Text('Value ${money(value)}', style: h(14))]),
        ),
        Expanded(
          child: _rows.isEmpty
              ? const Empty(Icons.inventory_2_outlined, 'Nothing here.')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, k) {
                    final p = _rows[k];
                    final q = d(p['on_hand']);
                    final low = q <= d(p['reorder']);
                    return Container(
                      decoration: box(),
                      child: ListTile(
                        title: Text(s(p['name']), style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${s(p['category'])}${d(p['reorder']) > 0 ? ' · reorder at ${qty(d(p['reorder']))}' : ''}'),
                        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text('${qty(q)} ${s(p['unit'])}', style: h(15, color: q <= 0 ? C.red : (low ? C.amber : C.text))),
                          Text(money(q > 0 ? q * d(p['cost']) : 0), style: const TextStyle(color: C.muted, fontSize: 12)),
                        ]),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MovesScreen(productId: n(p['id']), title: s(p['name'])))),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

// -----------------------------------------------------------------------------
// Products
// -----------------------------------------------------------------------------
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});
  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  List<Map<String, Object?>> _rows = [];
  String _q = '';
  bool _inactive = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.q(
        'SELECT p.*, c.name AS category, (SELECT COALESCE(SUM(qty),0) FROM stock s WHERE s.product_id = p.id) AS on_hand '
        'FROM products p LEFT JOIN categories c ON c.id = p.category_id WHERE p.active = ? ORDER BY p.name',
        [_inactive ? 0 : 1]);
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _open([int? id]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProductForm(id: id)));
    _load();
    changed();
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = _rows.where((p) => q.isEmpty || s(p['name']).toLowerCase().contains(q) || s(p['sku']).toLowerCase().contains(q) || s(p['barcode']) == q).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Products'), actions: [
        TextButton(onPressed: () { setState(() => _inactive = !_inactive); _load(); }, child: Text(_inactive ? 'Show active' : 'Show archived')),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _open(), icon: const Icon(Icons.add), label: const Text('Product')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(decoration: const InputDecoration(hintText: 'Search name, code, barcode', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => _q = v)),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Empty(Icons.sell_outlined, 'No products. Tap + Product.')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, k) {
                    final p = shown[k];
                    return Container(
                      decoration: box(),
                      child: ListTile(
                        leading: Avatar(s(p['name']), size: 40),
                        title: Text(s(p['name']), style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${s(p['category'])} · cost ${money(d(p['cost']), symbol: false)}${n(p['track']) == 1 ? ' · ${qty(d(p['on_hand']))} in stock' : ' · service'}'),
                        trailing: Text(money(d(p['price']), symbol: false), style: h(15)),
                        onTap: () => _open(n(p['id'])),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

class ProductForm extends StatefulWidget {
  final int? id;
  const ProductForm({super.key, this.id});
  @override
  State<ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<ProductForm> {
  final _name = TextEditingController();
  final _sku = TextEditingController();
  final _barcode = TextEditingController();
  final _price = TextEditingController();
  final _cost = TextEditingController();
  final _unit = TextEditingController(text: 'pcs');
  final _reorder = TextEditingController(text: '0');
  final _opening = TextEditingController();
  List<Map<String, Object?>> _cats = [];
  List<Map<String, Object?>> _locs = [];
  int? _cat;
  int _openLoc = 0;
  double _tax = 16;
  bool _track = true;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await Db.q('SELECT * FROM categories ORDER BY name');
    final l = await locations();
    Map<String, Object?>? p;
    if (widget.id != null) p = await Db.one('SELECT * FROM products WHERE id = ?', [widget.id]);
    if (!mounted) return;
    setState(() {
      _cats = c;
      _locs = l;
      _openLoc = l.isEmpty ? 0 : n(l.first['id']);
      _cat = c.isEmpty ? null : n(c.first['id']);
      if (p != null) {
        _name.text = s(p['name']);
        _sku.text = s(p['sku']);
        _barcode.text = s(p['barcode']);
        _price.text = qty(d(p['price']));
        _cost.text = qty(d(p['cost']));
        _unit.text = s(p['unit']);
        _reorder.text = qty(d(p['reorder']));
        _cat = p['category_id'] == null ? _cat : n(p['category_id']);
        _tax = d(p['tax_rate']);
        _track = n(p['track']) == 1;
        _active = n(p['active']) == 1;
      }
    });
  }

  Future<void> _save() async {
    final price = numIn(_price.text);
    if (_name.text.trim().isEmpty || price == null || price < 0) {
      toast(context, 'Enter the name and the selling price.');
      return;
    }
    final cost = numIn(_cost.text) ?? 0;
    final vals = {
      'name': _name.text.trim(), 'sku': _sku.text.trim(), 'barcode': _barcode.text.trim(), 'category_id': _cat,
      'price': price, 'cost': cost, 'tax_rate': _tax, 'unit': _unit.text.trim().isEmpty ? 'pcs' : _unit.text.trim(),
      'track': _track ? 1 : 0, 'reorder': numIn(_reorder.text) ?? 0, 'active': _active ? 1 : 0,
    };
    final db = await Db.get();
    try {
      await db.transaction((tx) async {
        if (widget.id == null) {
          final id = await Db.ins(tx, 'products', {...vals, 'created_at': nowIso()});
          final open = numIn(_opening.text) ?? 0;
          if (_track && open > 0 && _openLoc > 0) {
            await Stock.setCounted(tx, productId: id, locationId: _openLoc, counted: open, userId: Session.i.userId,
                opening: true, unitCost: cost, note: 'opening stock');
          }
        } else {
          await tx.update('products', vals, where: 'id = ?', whereArgs: [widget.id]);
        }
        await Db.audit(tx, Session.i.userId, widget.id == null ? 'product_add' : 'product_edit', '${vals['name']} price $price');
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.id == null ? 'New product' : 'Edit product')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name *')),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: TextField(controller: _price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Selling price *', helperText: 'incl. VAT'))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _cost, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Cost price', helperText: 'buying price'))),
          ]),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
            value: _cats.any((c) => n(c['id']) == _cat) ? _cat : null,
            decoration: const InputDecoration(labelText: 'Category'),
            items: [for (final c in _cats) DropdownMenuItem(value: n(c['id']), child: Text(s(c['name'])))],
            onChanged: (v) => setState(() => _cat = v),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<double>(
            value: _tax,
            decoration: const InputDecoration(labelText: 'VAT'),
            items: const [
              DropdownMenuItem(value: 16.0, child: Text('16% (standard)')),
              DropdownMenuItem(value: 8.0, child: Text('8% (fuel)')),
              DropdownMenuItem(value: 0.0, child: Text('0% / exempt')),
            ],
            onChanged: (v) => setState(() => _tax = v ?? 16),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: TextField(controller: _sku, decoration: const InputDecoration(labelText: 'Code (SKU)'))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _barcode, decoration: const InputDecoration(labelText: 'Barcode'))),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: TextField(controller: _unit, decoration: const InputDecoration(labelText: 'Unit (pcs, kg, bottle)'))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _reorder, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Reorder level'))),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _track,
            onChanged: (v) => setState(() => _track = v),
            title: const Text('Track stock'),
            subtitle: const Text('Off for services (no stock).'),
          ),
          if (widget.id == null && _track && Session.i.can(P.stockAdjust)) ...[
            const Label('Opening stock (optional)'),
            Row(children: [
              Expanded(child: TextField(controller: _opening, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Quantity now'))),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: _locs.any((l) => n(l['id']) == _openLoc) ? _openLoc : null,
                  decoration: const InputDecoration(labelText: 'At'),
                  items: [for (final l in _locs) DropdownMenuItem(value: n(l['id']), child: Text(s(l['name'])))],
                  onChanged: (v) => setState(() => _openLoc = v ?? 0),
                ),
              ),
            ]),
          ],
          if (widget.id != null)
            SwitchListTile(contentPadding: EdgeInsets.zero, value: _active, onChanged: (v) => setState(() => _active = v), title: const Text('Active (shown on the Sell screen)')),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ]),
      );
}

// -----------------------------------------------------------------------------
// Categories and locations (simple lists)
// -----------------------------------------------------------------------------
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});
  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.q('SELECT c.*, (SELECT COUNT(*) FROM products p WHERE p.category_id = c.id) AS cnt FROM categories c ORDER BY name');
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _edit([Map<String, Object?>? c]) async {
    final v = await ask(context, c == null ? 'New category' : 'Rename category', initial: s(c?['name']), label: 'Name');
    if (v == null || v.trim().isEmpty) return;
    final db = await Db.get();
    if (c == null) {
      await Db.ins(db, 'categories', {'name': v.trim()});
    } else {
      await db.update('categories', {'name': v.trim()}, where: 'id = ?', whereArgs: [c['id']]);
    }
    _load();
    changed();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Categories')),
        floatingActionButton: FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add)),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 90), children: [
          Container(
            decoration: box(),
            child: Column(children: [
              for (final c in _rows)
                ListTile(
                  title: Text(s(c['name'])),
                  subtitle: Text('${n(c['cnt'])} products'),
                  trailing: n(c['cnt']) == 0
                      ? IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final db = await Db.get();
                            await db.delete('categories', where: 'id = ?', whereArgs: [c['id']]);
                            _load();
                          },
                        )
                      : null,
                  onTap: () => _edit(c),
                ),
            ]),
          ),
        ]),
      );
}

class LocationsScreen extends StatefulWidget {
  const LocationsScreen({super.key});
  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.q('SELECT l.*, (SELECT COALESCE(SUM(qty),0) FROM stock s WHERE s.location_id = l.id) AS q FROM locations l ORDER BY active DESC, name');
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _edit([Map<String, Object?>? l]) async {
    final v = await ask(context, l == null ? 'New location' : 'Rename location', initial: s(l?['name']), label: 'e.g. Bar, Kitchen, Branch 2');
    if (v == null || v.trim().isEmpty) return;
    final db = await Db.get();
    if (l == null) {
      await Db.ins(db, 'locations', {'name': v.trim(), 'kind': 'shop'});
    } else {
      await db.update('locations', {'name': v.trim()}, where: 'id = ?', whereArgs: [l['id']]);
    }
    _load();
    changed();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Locations')),
        floatingActionButton: FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add)),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 90), children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Text('Stock is kept per location. Sell from a shop location; refill it from the store with requisitions.', style: muted),
          ),
          Container(
            decoration: box(),
            child: Column(children: [
              for (final l in _rows)
                ListTile(
                  title: Text(s(l['name']), style: TextStyle(color: n(l['active']) == 1 ? C.text : C.muted, fontWeight: FontWeight.w700)),
                  subtitle: Text('${s(l['kind']) == 'store' ? 'Store' : 'Selling point'} · ${qty(d(l['q']))} items${n(l['active']) == 1 ? '' : ' · archived'}'),
                  onTap: () => _edit(l),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      final db = await Db.get();
                      if (v == 'kind') {
                        await db.update('locations', {'kind': s(l['kind']) == 'store' ? 'shop' : 'store'}, where: 'id = ?', whereArgs: [l['id']]);
                      } else {
                        await db.update('locations', {'active': n(l['active']) == 1 ? 0 : 1}, where: 'id = ?', whereArgs: [l['id']]);
                      }
                      _load();
                      changed();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'kind', child: Text(s(l['kind']) == 'store' ? 'Make it a selling point' : 'Make it a store')),
                      PopupMenuItem(value: 'active', child: Text(n(l['active']) == 1 ? 'Archive' : 'Restore')),
                    ],
                  ),
                ),
            ]),
          ),
        ]),
      );
}

// -----------------------------------------------------------------------------
// Stock count
// -----------------------------------------------------------------------------
class StockCountScreen extends StatefulWidget {
  const StockCountScreen({super.key});
  @override
  State<StockCountScreen> createState() => _StockCountScreenState();
}

class _StockCountScreenState extends State<StockCountScreen> {
  List<Map<String, Object?>> _locs = [];
  int _loc = 0;
  List<Map<String, Object?>> _rows = [];
  final Map<int, TextEditingController> _c = {};
  String _q = '';
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final l = await locations();
    if (!mounted) return;
    setState(() {
      _locs = l;
      _loc = l.isEmpty ? 0 : n(l.first['id']);
    });
    _load();
  }

  Future<void> _load() async {
    final r = await Stock.list(locationId: _loc);
    for (final c in _c.values) {
      c.dispose();
    }
    _c.clear();
    for (final p in r) {
      _c[n(p['id'])] = TextEditingController();
    }
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _save() async {
    final changes = <(Map<String, Object?>, double)>[];
    for (final p in _rows) {
      final v = numIn(_c[n(p['id'])]?.text);
      if (v != null && (v - d(p['on_hand'])).abs() > 0.00001) changes.add((p, v));
    }
    if (changes.isEmpty) {
      toast(context, 'No differences typed.');
      return;
    }
    final value = changes.fold<double>(0, (a, e) => a + (e.$2 - d(e.$1['on_hand'])) * d(e.$1['cost']));
    if (!await confirm(context, 'Save ${changes.length} corrections?',
        '${changes.take(12).map((e) => '${e.$1['name']}: ${qty(d(e.$1['on_hand']))} → ${qty(e.$2)}').join('\n')}\n\nValue ${value >= 0 ? '+' : ''}${money(value)}',
        ok: 'Save')) {
      return;
    }
    final db = await Db.get();
    await db.transaction((tx) async {
      for (final e in changes) {
        await Stock.setCounted(tx, productId: n(e.$1['id']), locationId: _loc, counted: e.$2, userId: Session.i.userId, note: _reason.text.trim());
      }
    });
    changed();
    if (mounted) toast(context, 'Stock corrected.');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = _rows.where((p) => q.isEmpty || s(p['name']).toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Stock count')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                value: _locs.any((l) => n(l['id']) == _loc) ? _loc : null,
                decoration: const InputDecoration(labelText: 'Location'),
                items: [for (final l in _locs) DropdownMenuItem(value: n(l['id']), child: Text(s(l['name'])))],
                onChanged: (v) { setState(() => _loc = v ?? _loc); _load(); },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: TextField(decoration: const InputDecoration(hintText: 'Search', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => _q = v))),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Text('Type only what differs from the system figure. Empty = correct.', style: muted),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            itemCount: shown.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, k) {
              final p = shown[k];
              return Container(
                decoration: box(),
                padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s(p['name']), style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('System: ${qty(d(p['on_hand']))} ${s(p['unit'])}', style: muted),
                    ]),
                  ),
                  SizedBox(
                    width: 96,
                    child: TextField(
                      controller: _c[n(p['id'])],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(hintText: 'Counted'),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Column(children: [
              TextField(controller: _reason, decoration: const InputDecoration(hintText: 'Reason (e.g. monthly count, breakage)')),
              const SizedBox(height: 8),
              FilledButton(onPressed: _save, style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 52)), child: const Text('Save count')),
            ]),
          ),
        ),
      ]),
    );
  }
}

// -----------------------------------------------------------------------------
// Movements
// -----------------------------------------------------------------------------
class MovesScreen extends StatefulWidget {
  final int? productId;
  final String title;
  const MovesScreen({super.key, this.productId, this.title = 'Stock movements'});
  @override
  State<MovesScreen> createState() => _MovesScreenState();
}

class _MovesScreenState extends State<MovesScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    Db.q(
        'SELECT m.*, p.name AS product, p.unit, lf.name AS from_name, lt.name AS to_name, u.name AS user FROM stock_moves m '
        'LEFT JOIN products p ON p.id = m.product_id LEFT JOIN locations lf ON lf.id = m.from_loc LEFT JOIN locations lt ON lt.id = m.to_loc '
        'LEFT JOIN users u ON u.id = m.user_id ${widget.productId == null ? '' : 'WHERE m.product_id = ${widget.productId}'} '
        'ORDER BY m.id DESC LIMIT 300').then((r) {
      if (mounted) setState(() => _rows = r);
    });
  }

  static const _kinds = {
    'sale': 'Sale', 'refund': 'Refund', 'purchase': 'Purchase', 'transfer': 'Transfer', 'adjust': 'Count / adjustment', 'opening': 'Opening stock',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: _rows.isEmpty
            ? const Empty(Icons.swap_vert, 'No movements.')
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: _rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, k) {
                  final m = _rows[k];
                  final from = s(m['from_name']).isEmpty ? 'outside' : s(m['from_name']);
                  final to = s(m['to_name']).isEmpty ? 'outside' : s(m['to_name']);
                  final incoming = n(m['from_loc']) == 0;
                  final outgoing = n(m['to_loc']) == 0;
                  return Container(
                    decoration: box(),
                    child: ListTile(
                      title: Text(widget.productId == null ? s(m['product']) : (_kinds[s(m['kind'])] ?? s(m['kind'])),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${widget.productId == null ? '${_kinds[s(m['kind'])] ?? s(m['kind'])} · ' : ''}$from → $to · ${s(m['ref'])}\n'
                          '${dateText(m['date'])} · ${s(m['user'])}${s(m['note']).isEmpty ? '' : ' · ${s(m['note'])}'}'),
                      isThreeLine: true,
                      trailing: Text('${incoming ? '+' : (outgoing ? '-' : '')}${qty(d(m['qty']))}',
                          style: h(15, color: incoming ? C.green : (outgoing ? C.red : C.ink))),
                    ),
                  );
                },
              ),
      );
}

// -----------------------------------------------------------------------------
// Requisitions
// -----------------------------------------------------------------------------
class RequisitionsScreen extends StatefulWidget {
  const RequisitionsScreen({super.key});
  @override
  State<RequisitionsScreen> createState() => _RequisitionsScreenState();
}

class _RequisitionsScreenState extends State<RequisitionsScreen> {
  List<Map<String, Object?>> _rows = [];
  String _state = 'pending';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.q(
        'SELECT r.*, lf.name AS from_name, lt.name AS to_name, u.name AS user, '
        '(SELECT COUNT(*) FROM requisition_lines l WHERE l.requisition_id = r.id) AS items FROM requisitions r '
        'LEFT JOIN locations lf ON lf.id = r.from_loc LEFT JOIN locations lt ON lt.id = r.to_loc LEFT JOIN users u ON u.id = r.user_id '
        'WHERE r.state ${_state == 'pending' ? "= 'pending'" : "!= 'pending'"} ORDER BY r.id DESC LIMIT 200');
    if (mounted) setState(() => _rows = r);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Requisitions')),
        floatingActionButton: Session.i.can(P.reqCreate)
            ? FloatingActionButton.extended(
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RequisitionForm()));
                  _load();
                },
                icon: const Icon(Icons.add),
                label: const Text('Request'),
              )
            : null,
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: PeriodSwitch(value: _state, options: const [('pending', 'Waiting'), ('done', 'Done')], onChanged: (v) { setState(() => _state = v); _load(); }),
            ),
          ),
          Expanded(
            child: _rows.isEmpty
                ? const Empty(Icons.move_up_rounded, 'Nothing here.')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                    itemCount: _rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, k) {
                      final r = _rows[k];
                      final st = s(r['state']);
                      return Container(
                        decoration: box(),
                        child: ListTile(
                          title: Text('${s(r['number'])} · ${n(r['items'])} items', style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text('${s(r['from_name'])} → ${s(r['to_name'])}\n${dateText(r['date'])} · ${s(r['user'])}'),
                          isThreeLine: true,
                          trailing: Pill(
                            st == 'pending' ? 'Waiting' : (st == 'approved' ? 'Moved' : st == 'rejected' ? 'Rejected' : 'Cancelled'),
                            fg: st == 'approved' ? C.green : (st == 'pending' ? C.amber : C.red),
                            bg: st == 'approved' ? C.greenLight : (st == 'pending' ? C.amberLight : C.redLight),
                          ),
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RequisitionDetail(id: n(r['id']))));
                            _load();
                          },
                        ),
                      );
                    },
                  ),
          ),
        ]),
      );
}

/// Pick a product and a quantity (and a cost for purchases). Returns (product, qty, cost).
Future<(Map<String, Object?>, double, double)?> pickLine(BuildContext context, {bool withCost = false, int locationId = 0}) async {
  final products = await Stock.list(locationId: locationId, onlyTracked: !withCost);
  if (!context.mounted) return null;
  final p = await pickFrom(context, 'Item', products, sub: (m) => '${qty(d(m['on_hand']))} ${s(m['unit'])} here${withCost ? ' · cost ${money(d(m['cost']), symbol: false)}' : ''}');
  if (p == null || !context.mounted) return null;
  final q = numIn(await ask(context, 'Quantity of ${p['name']}', number: true));
  if (q == null || q <= 0 || !context.mounted) return null;
  var cost = d(p['cost']);
  if (withCost) {
    final c = numIn(await ask(context, 'Buying price per ${s(p['unit'])}', number: true, initial: qty(cost)));
    if (c == null || c < 0) return null;
    cost = c;
  }
  return (p, q, cost);
}

class RequisitionForm extends StatefulWidget {
  const RequisitionForm({super.key});
  @override
  State<RequisitionForm> createState() => _RequisitionFormState();
}

class _RequisitionFormState extends State<RequisitionForm> {
  List<Map<String, Object?>> _locs = [];
  int _from = 0, _to = 0;
  final List<(Map<String, Object?>, double)> _lines = [];
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    locations().then((l) {
      if (!mounted) return;
      final store = l.where((x) => s(x['kind']) == 'store').toList();
      final shop = l.where((x) => s(x['kind']) != 'store').toList();
      setState(() {
        _locs = l;
        _from = store.isNotEmpty ? n(store.first['id']) : (l.isNotEmpty ? n(l.first['id']) : 0);
        _to = n(Session.i.shift?['location_id']) > 0 ? n(Session.i.shift!['location_id']) : (shop.isNotEmpty ? n(shop.first['id']) : _from);
      });
    });
  }

  Future<void> _add() async {
    final r = await pickLine(context, locationId: _from);
    if (r != null) setState(() => _lines.add((r.$1, r.$2)));
  }

  Future<void> _save() async {
    try {
      await Requisitions.create(fromLoc: _from, toLoc: _to, lines: [for (final l in _lines) (n(l.$1['id']), l.$2)], note: _note.text.trim());
      changed();
      if (mounted) {
        toast(context, 'Request sent. A manager approves it to move the stock.');
        Navigator.pop(context);
      }
    } on SaleError catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  DropdownButtonFormField<int> _loc(String label, int v, ValueChanged<int> on) => DropdownButtonFormField<int>(
        value: _locs.any((l) => n(l['id']) == v) ? v : null,
        decoration: InputDecoration(labelText: label),
        items: [for (final l in _locs) DropdownMenuItem(value: n(l['id']), child: Text(s(l['name'])))],
        onChanged: (x) => setState(() => on(x ?? v)),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('New requisition')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          _loc('From (who gives)', _from, (v) => _from = v),
          const SizedBox(height: 10),
          _loc('To (who asks)', _to, (v) => _to = v),
          const Label('Items'),
          Container(
            decoration: box(),
            child: Column(children: [
              for (final l in _lines)
                ListTile(
                  title: Text(s(l.$1['name'])),
                  subtitle: Text('${qty(d(l.$1['on_hand']))} at the source'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(qty(l.$2), style: h(15)),
                    IconButton(onPressed: () => setState(() => _lines.remove(l)), icon: const Icon(Icons.close)),
                  ]),
                ),
              ListTile(leading: const Icon(Icons.add), title: const Text('Add item'), onTap: _add),
            ]),
          ),
          const SizedBox(height: 10),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note')),
          const SizedBox(height: 16),
          FilledButton(onPressed: _lines.isEmpty ? null : _save, child: const Text('Send request')),
        ]),
      );
}

class RequisitionDetail extends StatefulWidget {
  final int id;
  const RequisitionDetail({super.key, required this.id});
  @override
  State<RequisitionDetail> createState() => _RequisitionDetailState();
}

class _RequisitionDetailState extends State<RequisitionDetail> {
  Map<String, Object?>? _r;
  List<Map<String, Object?>> _lines = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.one(
        'SELECT r.*, lf.name AS from_name, lt.name AS to_name, u.name AS user, a.name AS approver FROM requisitions r '
        'LEFT JOIN locations lf ON lf.id = r.from_loc LEFT JOIN locations lt ON lt.id = r.to_loc '
        'LEFT JOIN users u ON u.id = r.user_id LEFT JOIN users a ON a.id = r.approved_by WHERE r.id = ?',
        [widget.id]);
    final l = await Db.q(
        'SELECT rl.*, p.name, p.unit, (SELECT COALESCE(SUM(qty),0) FROM stock s WHERE s.product_id = rl.product_id AND s.location_id = ?) AS have '
        'FROM requisition_lines rl JOIN products p ON p.id = rl.product_id WHERE rl.requisition_id = ?',
        [r?['from_loc'], widget.id]);
    if (mounted) setState(() { _r = r; _lines = l; });
  }

  Future<void> _approve() async {
    final none = _lines.every((l) => d(l['have']) <= 0);
    if (none) {
      toast(context, '${_r!['from_name']} has none of these items. Receive stock there first (purchase).');
      return;
    }
    final short = _lines.where((l) => d(l['have']) < d(l['qty'])).toList();
    if (!await confirm(context, 'Approve and move the stock?',
        short.isEmpty ? 'Everything asked is available.' : 'Not enough of:\n${short.map((l) => '${l['name']}: has ${qty(d(l['have']))}, asked ${qty(d(l['qty']))}').join('\n')}\n\nWhat is there will be moved.',
        ok: 'Approve')) {
      return;
    }
    try {
      final miss = await Requisitions.approve(widget.id);
      changed();
      if (mounted) toast(context, miss.isEmpty ? 'Approved. Stock moved.' : 'Approved. Short: ${miss.join('; ')}');
      _load();
    } on SaleError catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final pending = r != null && s(r['state']) == 'pending';
    final mine = r != null && n(r['user_id']) == Session.i.userId;
    return Scaffold(
      appBar: AppBar(title: Text(r == null ? 'Requisition' : s(r['number']))),
      body: r == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Container(
                decoration: box(),
                child: Column(children: [
                  KV('From', s(r['from_name'])),
                  KV('To', s(r['to_name'])),
                  KV('Asked by', '${s(r['user'])} · ${dateText(r['date'])}'),
                  KV('Status', s(r['state'])),
                  if (s(r['approver']).isNotEmpty) KV(s(r['state']) == 'approved' ? 'Approved by' : 'Closed by', '${s(r['approver'])} · ${dateText(r['approved_at'])}'),
                  if (s(r['note']).isNotEmpty) KV('Note', s(r['note'])),
                ]),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: box(),
                child: Column(children: [
                  for (final l in _lines)
                    ListTile(
                      title: Text(s(l['name']), style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(pending ? '${qty(d(l['have']))} ${s(l['unit'])} at ${s(r['from_name'])}' : 'Sent ${qty(d(l['qty_sent']))}'),
                      trailing: Text('${qty(d(l['qty']))} ${s(l['unit'])}', style: h(15, color: pending && d(l['have']) < d(l['qty']) ? C.red : C.text)),
                    ),
                ]),
              ),
              const SizedBox(height: 16),
              if (pending && Session.i.can(P.reqApprove)) ...[
                FilledButton.icon(onPressed: _approve, icon: const Icon(Icons.check), label: const Text('Approve (move stock)')),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () async {
                    await Requisitions.setState(widget.id, 'rejected');
                    changed();
                    _load();
                  },
                  style: OutlinedButton.styleFrom(foregroundColor: C.red),
                  child: const Text('Reject'),
                ),
              ] else if (pending && mine)
                OutlinedButton(
                  onPressed: () async {
                    await Requisitions.setState(widget.id, 'cancel');
                    changed();
                    _load();
                  },
                  child: const Text('Cancel my request'),
                ),
            ]),
    );
  }
}
