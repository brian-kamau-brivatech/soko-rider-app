import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'mgr_shell.dart';

/// Items: search, edit name / price / cost / available in POS / category / bar or kitchen, add new items.
class MgrItems extends StatefulWidget {
  const MgrItems({super.key});
  @override
  State<MgrItems> createState() => _MgrItemsState();
}

class _MgrItemsState extends State<MgrItems> {
  List<Map<String, dynamic>>? _items;
  List<Map<String, dynamic>> _cats = const [];
  String? _error;
  String _q = '';
  bool _onlyPos = true;

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
    if (mgrTab.value == 3 && _items == null) _load();
  }

  Future<void> _load() async {
    try {
      final meta = await Api.call('/utange/mgr/meta', {});
      final r = await Api.call('/utange/mgr/products', {'q': _q, 'only_pos': _onlyPos});
      if (mounted) {
        setState(() {
          _cats = ll(meta['categories']);
          _items = ll(r['products']);
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  Future<void> _edit([Map<String, dynamic>? p]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ItemEdit(item: p, categories: _cats)));
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        backgroundColor: C.green,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New item'),
      ),
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: C.green,
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 100), children: [
            Row(children: [
              Expanded(child: Text('Items', style: h(22))),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CategoryPoints())),
                icon: const Icon(Icons.category_rounded),
                label: const Text('Bar / Kitchen'),
              ),
            ]),
            const SizedBox(height: 8),
            TextField(
              onChanged: (v) => _q = v,
              onSubmitted: (_) => _load(),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search item, then Enter',
                prefixIcon: const Icon(Icons.search_rounded),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Only items available in POS'),
              value: _onlyPos,
              onChanged: (v) {
                setState(() => _onlyPos = v);
                _load();
              },
            ),
            if (items == null && _error == null)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: C.green)))
            else if (items == null)
              EmptyNote(Icons.wifi_off_rounded, _error!)
            else if (items.isEmpty)
              const EmptyNote(Icons.inventory_2_outlined, 'No items found.')
            else
              for (final p in items)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: card(14),
                  child: ListTile(
                    title: Text(ss(p['name']), style: h(14.5, w: FontWeight.w700)),
                    subtitle: Text([
                      ss(p['categ']).isEmpty ? 'No POS category' : ss(p['categ']),
                      if (ss(p['effective_point']).isNotEmpty) ss(p['effective_point']) == 'bar' ? 'Bar' : 'Kitchen',
                      if (p['store_qty'] != null) 'Store ${qty(dd(p['store_qty']))} · ${ss(p['here'])} ${qty(dd(p['here_qty']))}',
                      if (p['pos'] != true) 'NOT in POS',
                    ].join(' · ')),
                    trailing: Text(ksh(dd(p['price'])), style: h(14.5, color: C.green)),
                    onTap: () => _edit(p),
                  ),
                ),
          ]),
        ),
      ),
    );
  }
}

class ItemEdit extends StatefulWidget {
  final Map<String, dynamic>? item;
  final List<Map<String, dynamic>> categories;
  const ItemEdit({super.key, this.item, required this.categories});
  @override
  State<ItemEdit> createState() => _ItemEditState();
}

class _ItemEditState extends State<ItemEdit> {
  late final _name = TextEditingController(text: ss(widget.item?['name']));
  late final _price = TextEditingController(text: widget.item == null ? '' : qty(dd(widget.item!['price'])));
  late final _cost = TextEditingController(text: widget.item == null ? '' : qty(dd(widget.item!['cost'])));
  late final _barcode = TextEditingController(text: ss(widget.item?['barcode']));
  late bool _pos = widget.item == null ? true : widget.item!['pos'] == true;
  late bool _storable = widget.item == null ? true : widget.item!['storable'] == true;
  late int? _categ = ((widget.item?['categ_ids'] as List?) ?? const []).isEmpty ? null : ii((widget.item!['categ_ids'] as List).first);
  late String _point = ss(widget.item?['point']);
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _cost.dispose();
    _barcode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || double.tryParse(_price.text.trim()) == null) {
      toast(context, 'Enter the name and the selling price.');
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await Api.call('/utange/mgr/product_save', {
        if (widget.item != null) 'product_id': ii(widget.item!['id']),
        'name': _name.text.trim(),
        'price': double.parse(_price.text.trim()),
        if (double.tryParse(_cost.text.trim()) != null) 'cost': double.parse(_cost.text.trim()),
        'barcode': _barcode.text.trim(),
        'pos': _pos,
        'storable': _storable,
        'categ_ids': [if (_categ != null) _categ],
        'point': _point,
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
      appBar: bar(widget.item == null ? 'New item' : 'Edit item'),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 30), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: card(),
          child: Column(children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
            TextField(
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Selling price (incl. VAT as in POS)', prefixText: 'KSh '),
            ),
            TextField(
              controller: _cost,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Cost (optional)', prefixText: 'KSh '),
            ),
            TextField(controller: _barcode, decoration: const InputDecoration(labelText: 'Barcode (optional)')),
          ]),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(6),
          decoration: card(),
          child: Column(children: [
            SwitchListTile(title: const Text('Available in POS'), value: _pos, onChanged: (v) => setState(() => _pos = v)),
            SwitchListTile(
              title: const Text('Track stock (storable)'),
              subtitle: const Text('Off for food made in the kitchen that is not counted'),
              value: _storable,
              onChanged: (v) => setState(() => _storable = v),
            ),
            ListTile(
              title: const Text('POS category'),
              trailing: DropdownButton<int?>(
                value: _categ,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('None')),
                  for (final c in widget.categories) DropdownMenuItem<int?>(value: ii(c['id']), child: Text(ss(c['name']))),
                ],
                onChanged: (v) => setState(() => _categ = v),
              ),
            ),
            ListTile(
              title: const Text('Sold from'),
              subtitle: const Text('Empty = as set on the category'),
              trailing: DropdownButton<String>(
                value: _point,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: '', child: Text('Category')),
                  DropdownMenuItem(value: 'bar', child: Text('Bar')),
                  DropdownMenuItem(value: 'kitchen', child: Text('Kitchen')),
                  DropdownMenuItem(value: 'main', child: Text('POS default')),
                ],
                onChanged: (v) => setState(() => _point = v ?? ''),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 18),
        primaryButton('Save', _save, icon: Icons.save_rounded, busy: _saving),
      ]),
    );
  }
}

/// Set each POS category to Bar or Kitchen (where its items are taken off stock).
class CategoryPoints extends StatefulWidget {
  const CategoryPoints({super.key});
  @override
  State<CategoryPoints> createState() => _CategoryPointsState();
}

class _CategoryPointsState extends State<CategoryPoints> {
  List<Map<String, dynamic>>? _cats;
  String _info = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await Api.call('/utange/mgr/meta', {});
      if (mounted) {
        setState(() {
          _cats = ll(m['categories']);
          _info = 'Main store: ${ss(m['store'])}\nBar: ${ss(m['bar']).isEmpty ? '(not set)' : ss(m['bar'])}\n'
              'Kitchen: ${ss(m['kitchen']).isEmpty ? '(not set)' : ss(m['kitchen'])}';
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _set(Map<String, dynamic> c, String point) async {
    try {
      final r = await Api.call('/utange/mgr/category_point', {'category_id': ii(c['id']), 'point': point});
      if (mounted) toast(context, ss(r['message']));
      _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: bar('Bar / Kitchen'),
      body: Loader(
        loading: _cats == null,
        error: _error,
        onRetry: _load,
        child: () => ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: C.blueLight, borderRadius: BorderRadius.circular(14)),
            child: Text('$_info\n\nDrinks set to Bar come off the bar stock when sold; food set to Kitchen comes off the kitchen stock.',
                style: const TextStyle(color: C.navy)),
          ),
          const SizedBox(height: 12),
          for (final c in _cats!)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: card(14),
              child: ListTile(
                title: Text(ss(c['name']), style: h(14.5, w: FontWeight.w700)),
                subtitle: ss(c['point']).isEmpty && ss(c['effective']).isNotEmpty
                    ? Text('From parent: ${ss(c['effective']) == 'bar' ? 'Bar' : 'Kitchen'}')
                    : null,
                trailing: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: '', label: Text('—')),
                    ButtonSegment(value: 'bar', label: Text('Bar')),
                    ButtonSegment(value: 'kitchen', label: Text('Kitchen')),
                  ],
                  selected: {ss(c['point'])},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => _set(c, v.first),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
