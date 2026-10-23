import 'package:flutter/material.dart';
import '../db.dart';
import '../kra.dart';
import '../settings.dart';
import '../ui.dart';
import '../vscu.dart';
import 'items_screen.dart';

/// Add or edit an item. Saving also registers it with KRA (items/saveItems).
class ItemForm extends StatefulWidget {
  final Map<String, dynamic>? item;
  const ItemForm({super.key, this.item});
  @override
  State<ItemForm> createState() => _ItemFormState();
}

class _ItemFormState extends State<ItemForm> {
  late final Map<String, dynamic> it = {...?widget.item};
  late final _name = TextEditingController(text: '${it['name'] ?? ''}');
  late final _price = TextEditingController(text: it['price'] == null ? '' : (it['price'] as num).toStringAsFixed(2));
  late final _barcode = TextEditingController(text: '${it['barcode'] ?? ''}');
  late final _cls = TextEditingController(text: '${it['cls_cd'] ?? ''}');
  String _clsName = '';
  late String _tax = '${it['tax'] ?? 'B'}';
  late String _type = '${it['item_type'] ?? '2'}';
  late String _origin = '${it['origin'] ?? 'KE'}';
  late String _pkg = '${it['pkg_unit'] ?? 'NT'}';
  late String _qty = '${it['qty_unit'] ?? 'U'}';
  late bool _active = (it['active'] ?? 1) == 1;
  bool _busy = false;

  bool get _isNew => widget.item == null;
  bool get _registered => it['registered'] == 1;

  @override
  void initState() {
    super.initState();
    _lookupClass();
  }

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _barcode.dispose();
    _cls.dispose();
    super.dispose();
  }

  Future<void> _lookupClass() async {
    final cd = _cls.text.trim();
    if (cd.isEmpty) {
      setState(() => _clsName = '');
      return;
    }
    final db = await Db.get();
    final r = await db.query('item_classes', where: 'cd = ?', whereArgs: [cd], limit: 1);
    if (mounted) setState(() => _clsName = r.isEmpty ? '' : '${r.first['nm']}');
  }

  Future<void> _pickClass() async {
    final db = await Db.get();
    final count = (await db.rawQuery('SELECT COUNT(*) AS n FROM item_classes')).first['n'] as int? ?? 0;
    if (!mounted) return;
    if (count == 0) {
      if (!Settings.i.ready) {
        toast(context, 'Initialise in Settings first, or type the classification code.');
        return;
      }
      setState(() => _busy = true);
      final res = await Vscu.refreshItemClasses();
      if (!mounted) return;
      setState(() => _busy = false);
      if (!res.ok) {
        toast(context, 'Could not load KRA classifications: ${res.message}');
        return;
      }
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ClassPicker(),
    );
    if (picked == null) return;
    _cls.text = '${picked['cd']}';
    final t = '${picked['tax'] ?? ''}';
    setState(() {
      _clsName = '${picked['nm']}';
      if (Kra.find(Kra.taxTypes, t) != null) _tax = t;
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final price = double.tryParse(_price.text.trim().replaceAll(',', ''));
    final cls = _cls.text.trim();
    if (name.isEmpty) {
      toast(context, 'Enter the item name.');
      return;
    }
    if (price == null || price < 0) {
      toast(context, 'Enter a valid price.');
      return;
    }
    if (!RegExp(r'^\d{6,10}$').hasMatch(cls)) {
      toast(context, 'Pick the KRA item classification (a number code).');
      return;
    }

    setState(() => _busy = true);
    final db = await Db.get();
    final row = <String, dynamic>{
      'name': name,
      'price': r2(price),
      'tax': _tax,
      'cls_cd': cls,
      'item_type': _type,
      'origin': _origin,
      'pkg_unit': _pkg,
      'qty_unit': _qty,
      'barcode': _barcode.text.trim(),
      'active': _active ? 1 : 0,
    };
    // Did anything KRA holds change? Then it must be sent again.
    final krachanged = _isNew ||
        row.entries.any((e) => e.key != 'active' && '${it[e.key]}' != '${e.value}') ||
        !_registered;
    if (_isNew) {
      row['item_cd'] = await nextItemCode(_origin, _type, _pkg, _qty);
      row['created_at'] = DateTime.now().toIso8601String();
      row['registered'] = 0;
      row['id'] = await db.insert('items', row);
    } else {
      if (krachanged) row['registered'] = 0;
      await db.update('items', row, where: 'id = ?', whereArgs: [it['id']]);
      row['id'] = it['id'];
      row['item_cd'] = it['item_cd'];
    }

    String msg = 'Saved.';
    if (krachanged && Settings.i.ready) {
      final res = await Vscu.saveItem(row);
      msg = res.ok
          ? 'Saved and registered with KRA.'
          : 'Saved on this phone, but KRA registration failed: ${res.message}. It will be retried at the first sale.';
    } else if (krachanged) {
      msg = 'Saved. It will be registered with KRA after you initialise.';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    toast(context, msg);
    Navigator.of(context).pop(true);
  }

  Widget _drop(String label, String value, List<Code> list, ValueChanged<String> onChanged, {bool showCode = true}) {
    final items = [...list];
    if (Kra.find(items, value) == null) items.add(Code(value, value));
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: DropdownButtonFormField<String>(
        value: value,
        isExpanded: true,
        decoration: field(label),
        items: [
          for (final c in items)
            DropdownMenuItem(value: c.code, child: Text(showCode ? '${c.code} · ${c.name}' : c.name, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) {
          if (v != null) setState(() => onChanged(v));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final regError = '${it['reg_error'] ?? ''}';
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? 'New item' : 'Edit item', style: h(18))),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 40), children: [
          if (_busy) const LinearProgressIndicator(color: C.brand),
          if (!_isNew)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _registered ? C.greenLight : C.amberLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _registered
                    ? 'Registered with KRA · code ${it['item_cd']}'
                    : 'Not registered with KRA yet${regError.isEmpty ? '' : ': $regError'}',
                style: TextStyle(color: _registered ? C.green : C.amber, fontWeight: FontWeight.w600),
              ),
            ),
          Section('Item', [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: field('Name')),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: TextField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: field('Selling price (including VAT)', hint: '0.00'),
              ),
            ),
            _drop('Tax type', _tax, Kra.taxTypes, (v) => _tax = v, showCode: false),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: TextField(controller: _barcode, decoration: field('Barcode (optional)')),
            ),
          ]),
          Section('KRA details', [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: TextField(
                controller: _cls,
                keyboardType: TextInputType.number,
                onChanged: (_) => _lookupClass(),
                decoration: field('Item classification code',
                        help: _clsName.isEmpty ? 'Tap the list icon to search KRA\'s classifications.' : _clsName)
                    .copyWith(
                  suffixIcon: IconButton(icon: const Icon(Icons.list_alt_rounded), onPressed: _pickClass),
                ),
              ),
            ),
            _drop('Item type', _type, Kra.itemTypes, (v) => _type = v, showCode: false),
            _drop('Packaging unit', _pkg, Kra.pkgUnits, (v) => _pkg = v),
            _drop('Quantity unit', _qty, Kra.qtyUnits, (v) => _qty = v),
            _drop('Country of origin', _origin, Kra.origins, (v) => _origin = v),
            if (_isNew)
              const Padding(
                padding: EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Text('The KRA item code is made from these details when you save, and stays the same afterwards.',
                    style: TextStyle(color: C.muted, fontSize: 12.5)),
              ),
            const SizedBox(height: 14),
          ]),
          if (!_isNew)
            Section('Visibility', [
              SwitchListTile(
                title: const Text('Show on the Sell screen'),
                subtitle: const Text('KRA does not allow deleting registered items; hide them instead.'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            ]),
          SizedBox(height: 52, child: FilledButton(onPressed: _busy ? null : _save, child: const Text('Save item'))),
        ]),
      ),
    );
  }
}

class _ClassPicker extends StatefulWidget {
  const _ClassPicker();
  @override
  State<_ClassPicker> createState() => _ClassPickerState();
}

class _ClassPickerState extends State<_ClassPicker> {
  List<Map<String, dynamic>> _rows = [];
  String _q = '';

  @override
  void initState() {
    super.initState();
    _search('');
  }

  Future<void> _search(String q) async {
    _q = q;
    final db = await Db.get();
    final words = q.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final where = words.isEmpty ? null : words.map((_) => '(nm LIKE ? OR cd LIKE ?)').join(' AND ');
    final args = [for (final w in words) ...['%$w%', '$w%']];
    final r = await db.query('item_classes',
        where: where, whereArgs: args.isEmpty ? null : args, orderBy: 'lvl DESC, nm COLLATE NOCASE', limit: 150);
    if (mounted && q == _q) setState(() => _rows = r.map((e) => Map<String, dynamic>.from(e)).toList());
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: TextField(
            autofocus: true,
            decoration: field('Search e.g. bread, water, phone', prefix: const Icon(Icons.search_rounded)),
            onChanged: _search,
          ),
        ),
        Expanded(
          child: _rows.isEmpty
              ? const EmptyNote(Icons.search_off_rounded, 'No classification matches.')
              : ListView.builder(
                  padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
                  itemCount: _rows.length,
                  itemBuilder: (_, i) {
                    final r = _rows[i];
                    return ListTile(
                      dense: true,
                      title: Text('${r['nm']}'),
                      subtitle: Text('${r['cd']}${'${r['tax'] ?? ''}'.isEmpty ? '' : ' · tax ${r['tax']}'}'),
                      onTap: () => Navigator.pop(context, r),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
