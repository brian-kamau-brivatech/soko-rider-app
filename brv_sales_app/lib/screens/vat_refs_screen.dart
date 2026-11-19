import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../bus.dart';
import '../db.dart';
import '../fmt.dart';
import '../session.dart';
import '../settings.dart';
import '../sheet_file.dart';
import '../tax.dart';
import '../ui.dart';

/// More > VAT references: General (one legal reference per tax group) or Specify (the exact Schedule
/// paragraph on each item, picked from the list kept here). The list is shared with every device by sync.
class VatRefsScreen extends StatefulWidget {
  const VatRefsScreen({super.key});
  @override
  State<VatRefsScreen> createState() => _VatRefsScreenState();
}

class _VatRefsScreenState extends State<VatRefsScreen> {
  List<Map<String, Object?>> _rows = [];
  String _group = 'A';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.q('SELECT * FROM vat_refs ORDER BY tax_cd, code');
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _edit([Map<String, Object?>? row]) async {
    final code = TextEditingController(text: s(row?['code']));
    final text = TextEditingController(text: s(row?['text']));
    var group = row == null ? _group : s(row['tax_cd']);
    final ok = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(row == null ? 'New VAT reference' : 'Edit VAT reference'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: group,
                decoration: const InputDecoration(labelText: 'Tax group'),
                items: [for (final g in taxGroups) DropdownMenuItem(value: g.code, child: Text(g.label))],
                onChanged: (v) => set(() => group = v ?? group),
              ),
              const SizedBox(height: 8),
              TextField(controller: code, decoration: const InputDecoration(labelText: 'Reference', hintText: 'e.g. First Schedule, Part I, para 1')),
              const SizedBox(height: 8),
              TextField(controller: text, maxLines: 3, decoration: const InputDecoration(labelText: 'What it covers (optional)')),
            ]),
          ),
          actions: [
            if (row != null)
              TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), style: TextButton.styleFrom(foregroundColor: C.red), child: const Text('Delete')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), style: FilledButton.styleFrom(minimumSize: const Size(0, 42)), child: const Text('Save')),
          ],
        ),
      ),
    );
    final db = await Db.get();
    if (ok == 'delete' && row != null) {
      await db.delete('vat_refs', where: 'id = ?', whereArgs: [row['id']]);
    } else if (ok == 'save' && code.text.trim().isNotEmpty) {
      final v = {'tax_cd': group, 'code': code.text.trim(), 'text': text.text.trim()};
      if (row == null) {
        await db.transaction((tx) => Db.ins(tx, 'vat_refs', v));
      } else {
        await db.update('vat_refs', v, where: 'id = ?', whereArgs: [row['id']]);
      }
    } else {
      return;
    }
    changed();
    _load();
  }

  /// Excel/CSV with the columns: Tax type, Reference, Description. Same group + reference = updated.
  Future<void> _import() async {
    try {
      final bytes = await const MethodChannel('brv/print').invokeMethod<Uint8List>('pickFile');
      if (bytes == null) return;
      final rows = SheetFile.read(bytes);
      String k(String h) => h.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      final hi = rows.indexWhere((r) => r.map(k).any((h) => h.startsWith('reference') || h == 'paragraph' || h == 'code'));
      if (hi < 0) throw const FormatException('No header row with a "Reference" column.');
      final head = rows[hi].map(k).toList();
      final gi = head.indexWhere((h) => h.startsWith('tax'));
      final ri = head.indexWhere((h) => h.startsWith('reference') || h == 'paragraph' || h == 'code');
      final di = head.indexWhere((h) => h.startsWith('description') || h.startsWith('text') || h.startsWith('covers') || h == 'item');
      String at(List<String> r, int i) => i < 0 || i >= r.length ? '' : r[i].trim();
      var added = 0, updated = 0;
      final db = await Db.get();
      await db.transaction((tx) async {
        for (final r in rows.skip(hi + 1)) {
          final ref = at(r, ri);
          var g = at(r, gi).toUpperCase();
          if (ref.isEmpty) continue;
          if (!taxGroups.any((x) => x.code == g)) g = g.contains('ZERO') ? 'C' : (g.contains('NON') ? 'D' : (g.contains('8') ? 'E' : (g.contains('16') ? 'B' : 'A')));
          final old = await tx.rawQuery('SELECT id FROM vat_refs WHERE tax_cd = ? AND code = ?', [g, ref]);
          if (old.isEmpty) {
            await Db.ins(tx, 'vat_refs', {'tax_cd': g, 'code': ref, 'text': at(r, di)});
            added++;
          } else {
            await tx.update('vat_refs', {'text': at(r, di)}, where: 'id = ?', whereArgs: [old.first['id']]);
            updated++;
          }
        }
        await Db.audit(tx, Session.i.userId, 'vat_refs_import', '$added added, $updated updated');
      });
      changed();
      _load();
      if (mounted) toast(context, '$added added, $updated updated.');
    } on FormatException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (_) {
      if (mounted) toast(context, 'Could not read that file. Save it as .xlsx or CSV.');
    }
  }

  Future<void> _general(TaxGroup g) async {
    final v = await ask(context, 'General reference ${g.code}', initial: generalRef(g.code), hint: g.general);
    if (v == null) return;
    await Settings.i.set('vat_gen_${g.code}', v.trim() == g.general ? '' : v.trim());
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final specify = vatRefSpecify;
    final shown = _rows.where((r) => s(r['tax_cd']) == _group).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('VAT references'), actions: [
        IconButton(tooltip: 'Import Excel/CSV', onPressed: _import, icon: const Icon(Icons.upload_file)),
      ]),
      floatingActionButton: specify ? FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add)) : null,
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 90), children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'general', label: Text('General'), icon: Icon(Icons.gavel_outlined)),
            ButtonSegment(value: 'specify', label: Text('Specify'), icon: Icon(Icons.list_alt)),
          ],
          selected: {specify ? 'specify' : 'general'},
          onSelectionChanged: (v) async {
            await Settings.i.set('vat_ref_mode', v.first);
            setState(() {});
          },
        ),
        const SizedBox(height: 8),
        Text(
          specify
              ? 'Each item can carry its exact Schedule paragraph (choose it on the product). Items without one print the general reference.'
              : 'Receipts print one general legal reference for each tax group used.',
          style: muted,
        ),
        const Label('General references'),
        Container(
          decoration: box(),
          child: Column(children: [
            for (final g in taxGroups)
              ListTile(
                leading: CircleAvatar(backgroundColor: C.soft, child: Text(g.code, style: h(15))),
                title: Text(g.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(generalRef(g.code)),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _general(g),
              ),
          ]),
        ),
        if (specify) ...[
          const Label('Specific references'),
          Wrap(spacing: 8, children: [
            for (final g in taxGroups)
              ChoiceChip(
                label: Text('${g.code} (${_rows.where((r) => s(r['tax_cd']) == g.code).length})'),
                selected: _group == g.code,
                onSelected: (_) => setState(() => _group = g.code),
              ),
          ]),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            const Empty(Icons.list_alt, 'None for this group yet. Tap + or import the list (columns: Tax type, Reference, Description).'),
          for (final r in shown)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: box(),
              child: ListTile(
                title: Text(s(r['code']), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: s(r['text']).isEmpty ? null : Text(s(r['text'])),
                onTap: () => _edit(r),
              ),
            ),
        ],
      ]),
    );
  }
}

/// Pick a specific VAT reference for an item of [group]. Returns '' for "general", null when cancelled.
Future<String?> pickVatRef(BuildContext context, String group, {String current = ''}) async {
  final rows = await Db.q('SELECT * FROM vat_refs WHERE tax_cd = ? ORDER BY code', [group]);
  if (!context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        ListTile(title: Text('VAT reference (${taxGroup(group).label})', style: h(17))),
        ListTile(
          leading: Icon(current.isEmpty ? Icons.radio_button_checked : Icons.radio_button_off),
          title: const Text('General'),
          subtitle: Text(generalRef(group)),
          onTap: () => Navigator.pop(ctx, ''),
        ),
        for (final r in rows)
          ListTile(
            leading: Icon(current == s(r['code']) ? Icons.radio_button_checked : Icons.radio_button_off),
            title: Text(s(r['code'])),
            subtitle: s(r['text']).isEmpty ? null : Text(s(r['text'])),
            onTap: () => Navigator.pop(ctx, s(r['code'])),
          ),
        if (rows.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No specific references for this group. Add them in More > VAT references.')),
      ]),
    ),
  );
}
