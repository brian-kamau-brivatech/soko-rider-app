import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../bus.dart';
import '../config.dart';
import '../db.dart';
import '../etr/kra.dart' show Kra;
import '../fmt.dart';
import '../session.dart';
import '../sheet_file.dart';
import '../stock.dart';
import '../tax.dart';
import '../ui.dart';

/// Stock > Import items: products from an Excel (.xlsx) or CSV file. Categories are made by themselves.
/// Existing items (same code, else same barcode, else same name) are updated.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});
  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _Item {
  final int row;
  final Map<String, Object?> v;
  final String category;
  final double opening;
  final String error;
  int? existing;
  _Item(this.row, this.v, this.category, this.opening, this.error);
}

class _ImportScreenState extends State<ImportScreen> {
  List<_Item> _items = [];
  String _file = '';
  bool _busy = false;
  bool _trackNew = true;
  bool _hasTrackCol = false;

  static String _key(String h) => h.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static int _find(List<String> head, List<String> names, {bool starts = false}) {
    for (final nm in names) {
      final i = head.indexWhere((h) => starts ? h.startsWith(nm) : h == nm);
      if (i >= 0) return i;
    }
    return -1;
  }

  Future<void> _pick() async {
    try {
      final bytes = await const MethodChannel('brv/print').invokeMethod<Uint8List>('pickFile');
      if (bytes == null) return;
      setState(() => _busy = true);
      final rows = SheetFile.read(bytes);
      await _parse(rows);
    } on FormatException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, 'Could not read that file. Save it as .xlsx or CSV and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _parse(List<List<String>> rows) async {
    final hi = rows.indexWhere((r) => r.map(_key).any((h) => h == 'itemname' || h == 'name' || h == 'product' || h == 'productname'));
    if (hi < 0) throw const FormatException('No header row with an "Item name" column was found.');
    final head = rows[hi].map(_key).toList();
    final c = (
      code: _find(head, ['itemcode', 'code', 'sku']),
      name: _find(head, ['itemname', 'name', 'product', 'productname']),
      cat: _find(head, ['category', 'group']),
      price: _find(head, ['price', 'sellingprice'], starts: true),
      cost: _find(head, ['cost', 'costprice', 'buyingprice'], starts: true),
      tax: _find(head, ['taxtype', 'taxgroup', 'taxcode', 'tax']),
      rate: _find(head, ['taxrate', 'vatrate', 'vat'], starts: true),
      ref: _find(head, ['vatreference', 'vatref']),
      unit: _find(head, ['unit', 'qtyunit', 'quantityunit']),
      type: _find(head, ['itemtype']),
      origin: _find(head, ['origin', 'country']),
      barcode: _find(head, ['barcode']),
      active: _find(head, ['active']),
      cls: _find(head, ['kraitemclass', 'itemclass', 'kraclass', 'class']),
      pkg: _find(head, ['packagingunit', 'pkgunit', 'packaging']),
      track: _find(head, ['trackstock', 'track']),
      reorder: _find(head, ['reorderlevel', 'reorder']),
      opening: _find(head, ['openingstock', 'stock', 'quantity']),
    );
    String at(List<String> r, int i) => i < 0 || i >= r.length ? '' : r[i].trim();
    bool yes(String v, bool def) => v.isEmpty ? def : const ['yes', 'y', '1', 'true', 'active'].contains(v.toLowerCase());
    final out = <_Item>[];
    for (var k = hi + 1; k < rows.length; k++) {
      final r = rows[k];
      final name = at(r, c.name);
      if (name.isEmpty) continue;
      final price = numIn(at(r, c.price));
      // tax group: the letter, else from the rate (16 -> B, 8 -> E, 0 -> A), else B
      var tax = at(r, c.tax).toUpperCase();
      if (!taxGroups.any((g) => g.code == tax)) {
        final rate = numIn(at(r, c.rate).replaceAll('%', ''));
        tax = rate == null ? 'B' : taxCdOf({'tax_rate': rate});
      }
      final unitIn = at(r, c.unit);
      final kraUnit = Kra.qtyUnits.where((u) => u.code.toLowerCase() == unitIn.toLowerCase()).firstOrNull;
      final v = <String, Object?>{
        'name': name,
        'sku': at(r, c.code),
        'barcode': at(r, c.barcode),
        'price': price ?? 0,
        if (c.cost >= 0) 'cost': numIn(at(r, c.cost)) ?? 0,
        'tax_cd': tax,
        'tax_rate': taxGroup(tax).rate,
        if (c.ref >= 0) 'vat_ref': at(r, c.ref).toLowerCase() == 'general' ? '' : at(r, c.ref),
        'unit': unitIn.isEmpty || kraUnit?.code == 'U' ? 'pcs' : (kraUnit != null ? kraUnit.name.toLowerCase() : unitIn),
        if (kraUnit != null) 'qty_unit': kraUnit.code,
        if (at(r, c.type).isNotEmpty) 'item_type': at(r, c.type),
        if (at(r, c.origin).isNotEmpty) 'origin': at(r, c.origin).toUpperCase(),
        if (at(r, c.cls).isNotEmpty) 'cls_cd': at(r, c.cls),
        if (at(r, c.pkg).isNotEmpty) 'pkg_unit': at(r, c.pkg).toUpperCase(),
        if (c.track >= 0) 'track': yes(at(r, c.track), true) ? 1 : 0,
        if (c.reorder >= 0) 'reorder': numIn(at(r, c.reorder)) ?? 0,
        'active': yes(at(r, c.active), true) ? 1 : 0,
      };
      final err = price == null || price < 0 ? 'No price' : '';
      out.add(_Item(k + 1, v, at(r, c.cat), numIn(at(r, c.opening)) ?? 0, err));
    }
    // match existing products: same code, else same barcode, else same name
    final all = await Db.q('SELECT id, name, sku, barcode FROM products');
    for (final it in out) {
      final sku = s(it.v['sku']), bc = s(it.v['barcode']), nm = s(it.v['name']).toLowerCase();
      final hit = all.where((p) => sku.isNotEmpty && s(p['sku']) == sku).firstOrNull ??
          all.where((p) => bc.isNotEmpty && s(p['barcode']) == bc).firstOrNull ??
          all.where((p) => s(p['name']).toLowerCase() == nm).firstOrNull;
      it.existing = hit == null ? null : n(hit['id']);
    }
    setState(() {
      _items = out;
      _hasTrackCol = c.track >= 0;
      _file = '${out.length} items read';
    });
  }

  Future<void> _import() async {
    final good = _items.where((i) => i.error.isEmpty).toList();
    if (good.isEmpty) return;
    setState(() => _busy = true);
    var added = 0, updated = 0, cats = 0;
    try {
      final db = await Db.get();
      final loc = await Db.one("SELECT id FROM locations WHERE active = 1 ORDER BY kind = 'shop' DESC, id LIMIT 1");
      await db.transaction((tx) async {
        final catIds = <String, int>{};
        for (final r in await tx.rawQuery('SELECT id, name FROM categories')) {
          catIds[s(r['name']).toLowerCase()] = n(r['id']);
        }
        for (final it in good) {
          int? cat;
          if (it.category.isNotEmpty) {
            cat = catIds[it.category.toLowerCase()];
            if (cat == null) {
              cat = await Db.ins(tx, 'categories', {'name': it.category, 'color': catIds.length % 8});
              catIds[it.category.toLowerCase()] = cat;
              cats++;
            }
          }
          final vals = {...it.v, if (cat != null) 'category_id': cat, 'kra_reg': 0, 'kra_err': ''}; // changed items register again
          if (it.existing != null) {
            await tx.update('products', vals, where: 'id = ?', whereArgs: [it.existing]);
            updated++;
          } else {
            final track = _hasTrackCol ? n(vals['track']) : (_trackNew ? 1 : 0);
            final id = await Db.ins(tx, 'products', {...vals, 'track': track, 'created_at': nowIso()});
            if (track == 1 && it.opening > 0 && loc != null) {
              await Stock.setCounted(tx, productId: id, locationId: n(loc['id']), counted: it.opening, userId: Session.i.userId,
                  opening: true, unitCost: d(vals['cost']), note: 'opening stock (import)');
            }
            added++;
          }
        }
        await Db.audit(tx, Session.i.userId, 'import_items', '$added added, $updated updated, $cats categories');
      });
      changed();
      if (!mounted) return;
      toast(context, '$added added, $updated updated${cats > 0 ? ', $cats new categories' : ''}.${isEtrApp ? ' Items register with KRA at their first sale (or More > KRA eTIMS device).' : ''}');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) toast(context, 'Import stopped, nothing saved: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bad = _items.where((i) => i.error.isNotEmpty).length;
    final upd = _items.where((i) => i.error.isEmpty && i.existing != null).length;
    final add = _items.where((i) => i.error.isEmpty && i.existing == null).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Import items')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        if (_items.isEmpty) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: box(),
            child: const Text(
              'Choose an Excel (.xlsx) or CSV file with one item per row. The first row holds the column names:\n\n'
              '• Item name and Price (VAT incl.): needed\n'
              '• Item code, Category, Cost, Barcode, Unit, Reorder level, Opening stock, Track stock (Yes/No), Active (Yes/No)\n'
              '• Tax type: A Exempt, B 16%, C Zero-rated, D Non-VAT, E 8% (or a Tax rate % column)\n'
              '• VAT reference (the Schedule paragraph, or General)\n'
              '• KRA: Item class, Item type (1 raw, 2 finished, 3 service), Origin (KE), Packaging unit (NT)\n\n'
              'Categories are created by themselves. An item with the same code (or barcode, or name) is updated, not doubled.',
              style: TextStyle(height: 1.4),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _busy ? null : _pick, icon: const Icon(Icons.upload_file), label: Text(_busy ? 'Reading...' : 'Choose file')),
        ] else ...[
          Row(children: [
            Expanded(child: StatTile(dark: true, value: '$add', label: 'New items', progress: 1, note: _file)),
            const SizedBox(width: 12),
            Expanded(child: StatTile(value: '$upd', label: 'Updates', progress: _items.isEmpty ? 0 : upd / _items.length, note: bad > 0 ? '$bad with errors' : 'no errors', bar: bad > 0 ? C.red : C.green)),
          ]),
          if (!_hasTrackCol)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _trackNew,
              onChanged: (v) => setState(() => _trackNew = v),
              title: const Text('Track stock for new items'),
              subtitle: const Text('Off for food, drinks made to order and services: they sell without stock.'),
            ),
          const Label('Items'),
          for (final it in _items.take(300))
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: box(),
              child: ListTile(
                dense: true,
                title: Text(s(it.v['name']), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text([
                  if (it.category.isNotEmpty) it.category,
                  'tax ${it.v['tax_cd']}',
                  if (s(it.v['sku']).isNotEmpty) s(it.v['sku']),
                  if (it.error.isNotEmpty) 'row ${it.row}: ${it.error}',
                ].join(' · '), style: TextStyle(color: it.error.isNotEmpty ? C.red : C.muted)),
                trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(money(d(it.v['price']), symbol: false), style: h(14)),
                  Text(it.existing == null ? 'new' : 'update', style: const TextStyle(fontSize: 11, color: C.muted)),
                ]),
              ),
            ),
          if (_items.length > 300) Text('... and ${_items.length - 300} more', style: muted),
          const SizedBox(height: 12),
          FilledButton(onPressed: _busy || add + upd == 0 ? null : _import, child: Text(_busy ? 'Importing...' : 'Import ${add + upd} items')),
          TextButton(onPressed: _busy ? null : _pick, child: const Text('Choose another file')),
        ],
      ]),
    );
  }
}
