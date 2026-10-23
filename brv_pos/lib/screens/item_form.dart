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

/// The five KRA tax groups, explained.
const taxGroups = [
  ('A', 'A · Exempt', 'No VAT (exempt supplies)'),
  ('B', 'B · VAT 16%', 'Standard rate: most goods and services'),
  ('C', 'C · Zero rated', 'VAT 0% (zero-rated supplies)'),
  ('D', 'D · Non-VAT', 'Not subject to VAT'),
  ('E', 'E · VAT 8%', 'Reduced rate, e.g. petroleum products'),
];

class _ItemFormState extends State<ItemForm> {
  late final Map<String, dynamic> it = {...?widget.item};
  late final _name = TextEditingController(text: '${it['name'] ?? ''}');
  late final _price = TextEditingController(text: it['price'] == null ? '' : (it['price'] as num).toStringAsFixed(2));
  late final _barcode = TextEditingController(text: '${it['barcode'] ?? ''}');
  late final _cls = TextEditingController(text: '${it['cls_cd'] ?? ''}');
  late final _code = TextEditingController(text: '${it['item_cd'] ?? ''}');
  String _clsName = '';
  late String _tax = '${it['tax'] ?? 'B'}';
  late String _type = '${it['item_type'] ?? '2'}';
  late String _origin = '${it['origin'] ?? 'KE'}';
  late String _pkg = '${it['pkg_unit'] ?? 'NT'}';
  late String _qty = '${it['qty_unit'] ?? 'U'}';
  late bool _active = (it['active'] ?? 1) == 1;
  bool _fromKra = false; // picked from items already registered at KRA
  bool _busy = false;

  bool get _isNew => widget.item == null;
  bool get _registered => it['registered'] == 1;
  bool get _codeLocked => !_isNew && _registered;

  @override
  void initState() {
    super.initState();
    _lookupClass();
    _price.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final c in [_name, _price, _barcode, _cls, _code]) {
      c.dispose();
    }
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
        toast(context, 'Set up the device in Settings first.');
        return;
      }
      setState(() => _busy = true);
      final res = await Vscu.refreshItemClasses();
      if (!mounted) return;
      setState(() => _busy = false);
      if (!res.ok) toast(context, 'Could not load the KRA list (${res.message}). You can type the code.');
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

  /// Choose an item code already registered at KRA for this PIN and branch.
  Future<void> _pickKraItem() async {
    if (!Settings.i.ready) {
      toast(context, 'Set up the device in Settings first.');
      return;
    }
    setState(() => _busy = true);
    final (res, list) = await Vscu.registeredItems();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!res.ok) {
      toast(context, 'Could not load KRA items: ${res.message}');
      return;
    }
    if (list.isEmpty) {
      toast(context, 'No items are registered at KRA for this branch yet. Use Generate.');
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _KraItemPicker(list),
    );
    if (picked == null) return;
    String v(String k) => picked[k] == null ? '' : '${picked[k]}';
    setState(() {
      _fromKra = true;
      _code.text = v('itemCd');
      if (_name.text.trim().isEmpty) _name.text = v('itemNm');
      if (v('itemClsCd').isNotEmpty) _cls.text = v('itemClsCd');
      if (Kra.find(Kra.taxTypes, v('taxTyCd')) != null) _tax = v('taxTyCd');
      if (v('itemTyCd').isNotEmpty) _type = v('itemTyCd');
      if (v('orgnNatCd').isNotEmpty) _origin = v('orgnNatCd');
      if (v('pkgUnitCd').isNotEmpty) _pkg = v('pkgUnitCd');
      if (v('qtyUnitCd').isNotEmpty) _qty = v('qtyUnitCd');
      if (v('bcd').isNotEmpty && v('bcd') != 'null') _barcode.text = v('bcd');
      final p = double.tryParse(v('dftPrc'));
      if (_price.text.trim().isEmpty && p != null && p > 0) _price.text = p.toStringAsFixed(2);
    });
    _lookupClass();
  }

  Future<void> _generate() async {
    final code = await nextItemCode(_origin, _type, _pkg, _qty);
    setState(() {
      _fromKra = false;
      _code.text = code;
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final price = _price.text.trim().isEmpty ? 0.0 : double.tryParse(_price.text.trim().replaceAll(',', ''));
    final cls = _cls.text.trim();
    var code = _code.text.trim().toUpperCase();
    String? err;
    if (name.isEmpty) err = 'Enter the item name.';
    if (err == null && (price == null || price < 0)) err = 'The default price is not a valid number.';
    if (err == null && !RegExp(r'^\d{6,10}$').hasMatch(cls)) err = 'Select the KRA item classification.';
    if (err == null && code.isNotEmpty && !RegExp(r'^[A-Z0-9]{3,20}$').hasMatch(code)) {
      err = 'Item code: 3 to 20 letters or numbers.';
    }
    if (err != null) {
      toast(context, err);
      return;
    }

    setState(() => _busy = true);
    final db = await Db.get();
    if (code.isEmpty) code = await nextItemCode(_origin, _type, _pkg, _qty);
    final clash = await db.query('items',
        columns: ['name'], where: 'item_cd = ? AND id != ?', whereArgs: [code, it['id'] ?? -1], limit: 1);
    if (clash.isNotEmpty) {
      if (!mounted) return;
      setState(() => _busy = false);
      toast(context, 'Item code $code is already used by "${clash.first['name']}".');
      return;
    }
    final row = <String, dynamic>{
      'name': name,
      'price': r2(price!),
      'tax': _tax,
      'cls_cd': cls,
      'item_type': _type,
      'origin': _origin,
      'pkg_unit': _pkg,
      'qty_unit': _qty,
      'barcode': _barcode.text.trim(),
      'item_cd': code,
      'active': _active ? 1 : 0,
    };
    // Did anything KRA holds change? Then it must be sent again.
    final krachanged = _isNew ||
        row.entries.any((e) => e.key != 'active' && '${it[e.key] ?? ''}' != '${e.value}') ||
        !_registered;
    if (_isNew) {
      row['created_at'] = DateTime.now().toIso8601String();
      row['registered'] = 0;
      row['id'] = await db.insert('items', row);
    } else {
      if (krachanged) row['registered'] = 0;
      await db.update('items', row, where: 'id = ?', whereArgs: [it['id']]);
      row['id'] = it['id'];
    }

    String msg = 'Saved.';
    if (krachanged && Settings.i.ready) {
      final res = await Vscu.saveItem(row);
      msg = res.ok
          ? (_fromKra ? 'Saved. Linked to the KRA item $code.' : 'Saved and registered with KRA.')
          : 'Saved on this phone, but KRA registration failed: ${res.message}. It will be retried at the first sale.';
    } else if (krachanged) {
      msg = 'Saved. It will be registered with KRA once the device is set up.';
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

  Widget _vatNote() {
    final p = double.tryParse(_price.text.trim().replaceAll(',', ''));
    if (p == null || p <= 0) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(14, 6, 14, 0),
        child: Text('Prices are entered at each sale (VAT inclusive). A default here only pre-fills it.', style: TextStyle(color: C.muted, fontSize: 12.5)),
      );
    }
    final rate = Kra.rate(_tax);
    final ex = r2(p * 100 / (100 + rate));
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      child: Text(
        rate > 0
            ? 'Includes VAT ${rate.toStringAsFixed(0)}%: ${money(r2(p - ex))} · before VAT ${money(ex)}'
            : 'No VAT in this price (tax group $_tax).',
        style: const TextStyle(color: C.brand2, fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final regError = '${it['reg_error'] ?? ''}';
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? 'New item' : 'Edit item')),
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
              child: TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: field('Item name')),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: TextField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: field('Default price (optional, VAT inclusive)', hint: 'Entered at each sale', prefix: const Padding(
                  padding: EdgeInsets.fromLTRB(14, 14, 6, 0),
                  child: Text('KSh', style: TextStyle(fontWeight: FontWeight.w700)),
                )),
              ),
            ),
            _vatNote(),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: TextField(controller: _barcode, decoration: field('Barcode (optional)')),
            ),
          ]),
          Section('Tax group', [
            for (final g in taxGroups)
              RadioListTile<String>(
                value: g.$1,
                groupValue: _tax,
                activeColor: C.brand,
                title: Text(g.$2, style: h(15, w: FontWeight.w700)),
                subtitle: Text(g.$3),
                onChanged: (v) => setState(() => _tax = v ?? _tax),
              ),
          ]),
          Section('KRA item code', [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: TextField(
                controller: _code,
                readOnly: _codeLocked,
                textCapitalization: TextCapitalization.characters,
                decoration: field('Item code',
                    hint: 'Leave empty to generate',
                    help: _codeLocked
                        ? 'Registered at KRA: the code cannot change.'
                        : 'Pick an item already registered at KRA (e.g. from Odoo), generate a new one, or type it.'),
              ),
            ),
            if (!_codeLocked)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickKraItem,
                      icon: const Icon(Icons.cloud_download_outlined),
                      label: const Text('Pick from KRA'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _generate,
                      icon: const Icon(Icons.auto_awesome_rounded),
                      label: const Text('Generate'),
                    ),
                  ),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: TextField(
                controller: _cls,
                readOnly: true,
                onTap: _pickClass,
                decoration: field('Item classification', hint: 'Tap to select',
                        help: _clsName.isEmpty ? 'KRA\'s list of goods and services. Tap to search.' : _clsName)
                    .copyWith(suffixIcon: const Icon(Icons.arrow_drop_down_rounded)),
              ),
            ),
            _drop('Item type', _type, Kra.itemTypes, (v) => _type = v, showCode: false),
            _drop('Packaging unit', _pkg, Kra.pkgUnits, (v) => _pkg = v),
            _drop('Quantity unit', _qty, Kra.qtyUnits, (v) => _qty = v),
            _drop('Country of origin', _origin, Kra.origins, (v) => _origin = v),
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

class _KraItemPicker extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  const _KraItemPicker(this.items);
  @override
  State<_KraItemPicker> createState() => _KraItemPickerState();
}

class _KraItemPickerState extends State<_KraItemPicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final list = widget.items
        .where((e) => q.isEmpty || '${e['itemNm']} ${e['itemCd']}'.toLowerCase().contains(q))
        .take(300)
        .toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: TextField(
            decoration: field('Search ${widget.items.length} KRA items', prefix: const Icon(Icons.search_rounded)),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final e = list[i];
              final p = double.tryParse('${e['dftPrc']}');
              return ListTile(
                dense: true,
                title: Text('${e['itemNm']}', style: h(14, w: FontWeight.w700)),
                subtitle: Text('${e['itemCd']} · tax ${e['taxTyCd']}'),
                trailing: p == null ? null : Text(money(p, symbol: false)),
                onTap: () => Navigator.pop(context, e),
              );
            },
          ),
        ),
      ]),
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
        if (RegExp(r'^\d{6,10}$').hasMatch(_q.trim()))
          ListTile(
            leading: const Icon(Icons.keyboard_rounded, color: C.brand),
            title: Text('Use code ${_q.trim()}', style: h(15, w: FontWeight.w700)),
            subtitle: const Text('Type the full KRA classification code if it is not in the list'),
            onTap: () => Navigator.pop(context, <String, dynamic>{'cd': _q.trim(), 'nm': 'Classification ${_q.trim()}', 'tax': ''}),
          ),
        Expanded(
          child: _rows.isEmpty
              ? const EmptyNote(Icons.search_off_rounded, 'No match in the list. Type the full code (e.g. 50202300) to use it.')
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
