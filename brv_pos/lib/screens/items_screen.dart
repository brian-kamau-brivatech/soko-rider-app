import 'package:flutter/material.dart';
import '../db.dart';
import '../kra.dart';
import '../settings.dart';
import '../ui.dart';
import '../vscu.dart';
import 'item_form.dart';

/// Items notify this when they change so the Sell screen reloads.
final itemsVersion = ValueNotifier<int>(0);

class ItemsScreen extends StatefulWidget {
  const ItemsScreen({super.key});
  @override
  State<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends State<ItemsScreen> {
  List<Map<String, dynamic>> _items = [];
  String _q = '';
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    itemsVersion.addListener(_load);
  }

  @override
  void dispose() {
    itemsVersion.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final db = await Db.get();
    final r = await db.query('items', orderBy: 'active DESC, name COLLATE NOCASE');
    if (mounted) {
      setState(() {
        _items = r.map((e) => Map<String, dynamic>.from(e)).toList();
        _loading = false;
      });
    }
  }

  Future<void> _open([Map<String, dynamic>? item]) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ItemForm(item: item)));
    if (changed == true) itemsVersion.value++;
  }

  Future<void> _registerAll() async {
    final todo = _items.where((e) => e['registered'] != 1 && e['active'] == 1).toList();
    if (todo.isEmpty) {
      toast(context, 'All items are registered with KRA.');
      return;
    }
    setState(() => _busy = true);
    var ok = 0;
    String? last;
    for (final it in todo) {
      final res = await Vscu.saveItem(it);
      if (res.ok) {
        ok++;
      } else {
        last = res.message;
        if (res.noAnswer) break;
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    itemsVersion.value++;
    toast(context, last == null ? 'Registered $ok item(s) with KRA.' : 'Registered $ok of ${todo.length}. Last error: $last');
  }

  /// Bring in items already registered at KRA for this branch (e.g. from Odoo).
  Future<void> _importKra() async {
    setState(() => _busy = true);
    final (res, list) = await Vscu.registeredItems();
    if (!mounted) return;
    if (!res.ok) {
      setState(() => _busy = false);
      toast(context, 'Could not load KRA items: ${res.message}');
      return;
    }
    final db = await Db.get();
    var added = 0;
    for (final e in list) {
      String v(String k) => e[k] == null || '${e[k]}' == 'null' ? '' : '${e[k]}';
      if (v('itemCd').isEmpty || v('useYn') == 'N') continue;
      final have = await db.query('items', columns: ['id'], where: 'item_cd = ?', whereArgs: [v('itemCd')], limit: 1);
      if (have.isNotEmpty) continue;
      await db.insert('items', {
        'name': v('itemNm').isEmpty ? v('itemCd') : v('itemNm'),
        'price': r2(double.tryParse(v('dftPrc')) ?? 0),
        'tax': Kra.find(Kra.taxTypes, v('taxTyCd')) == null ? 'B' : v('taxTyCd'),
        'cls_cd': v('itemClsCd'),
        'item_type': v('itemTyCd').isEmpty ? '2' : v('itemTyCd'),
        'origin': v('orgnNatCd').isEmpty ? 'KE' : v('orgnNatCd'),
        'pkg_unit': v('pkgUnitCd').isEmpty ? 'NT' : v('pkgUnitCd'),
        'qty_unit': v('qtyUnitCd').isEmpty ? 'U' : v('qtyUnitCd'),
        'barcode': v('bcd'),
        'item_cd': v('itemCd'),
        'registered': 1,
        'active': 1,
        'created_at': DateTime.now().toIso8601String(),
      });
      added++;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    itemsVersion.value++;
    toast(context, list.isEmpty
        ? 'No items are registered at KRA for this branch yet.'
        : 'Imported $added new item(s) of ${list.length} registered at KRA. Check their prices.');
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final list = q.isEmpty
        ? _items
        : _items.where((e) => '${e['name']} ${e['barcode']} ${e['item_cd']}'.toLowerCase().contains(q)).toList();
    final unregistered = _items.where((e) => e['registered'] != 1 && e['active'] == 1).length;
    return Scaffold(
      appBar: AppBar(title: Text('Items'), actions: [
        if (unregistered > 0 && Settings.i.ready)
          TextButton.icon(
            onPressed: _busy ? null : _registerAll,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text('Register $unregistered'),
          ),
        if (Settings.i.ready)
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'import') _importKra();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'import', child: Text('Import items registered at KRA')),
            ],
          ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New item'),
      ),
      body: Column(children: [
        if (_busy) const LinearProgressIndicator(color: C.brand),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: TextField(
            decoration: field('Search name, barcode or code', prefix: const Icon(Icons.search_rounded)),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : list.isEmpty
                  ? EmptyNote(Icons.inventory_2_outlined,
                      _items.isEmpty ? 'No items yet.\nTap New item to add what you sell.' : 'Nothing matches "$_q".')
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 90),
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final it = list[i];
                        final reg = it['registered'] == 1;
                        final active = it['active'] == 1;
                        return InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => _open(it),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: card(14),
                            child: Row(children: [
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text('${it['name']}',
                                      style: h(15.5, w: FontWeight.w700, color: active ? C.ink : C.muted)),
                                  const SizedBox(height: 4),
                                  Wrap(spacing: 6, runSpacing: 4, children: [
                                    Pill('Tax ${it['tax']}'),
                                    if (!active) const Pill('Hidden'),
                                    reg
                                        ? const Pill('KRA ✓', fg: C.green, bg: C.greenLight)
                                        : Pill((it['reg_error'] ?? '').toString().isEmpty ? 'Not registered' : 'KRA error',
                                            fg: C.amber, bg: C.amberLight),
                                  ]),
                                ]),
                              ),
                              Text(((it['price'] as num?) ?? 0) > 0 ? money((it['price'] as num).toDouble()) : 'Price at sale', style: h(14.5, color: C.muted)),
                            ]),
                          ),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}

/// Item code for a new item: origin + type + packaging + quantity unit + sequence.
Future<String> nextItemCode(String origin, String type, String pkg, String qty) async {
  final db = await Db.get();
  final n = int.tryParse(await Db.kv('item_seq') ?? '') ?? 0;
  var seq = n + 1;
  // Never reuse a code that already exists on this phone.
  while (true) {
    final code = makeItemCode(origin: origin, type: type, pkg: pkg, qty: qty, seq: seq);
    final r = await db.query('items', columns: ['id'], where: 'item_cd = ?', whereArgs: [code], limit: 1);
    if (r.isEmpty) {
      await Db.setKv('item_seq', '$seq');
      return code;
    }
    seq++;
  }
}
