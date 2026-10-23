import 'package:flutter/material.dart';
import '../db.dart';
import '../ui.dart';

/// Customers (name, KRA PIN, phone). [pick] returns the chosen customer.
class CustomersScreen extends StatefulWidget {
  final bool pick;
  const CustomersScreen({super.key, this.pick = false});
  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  List<Map<String, dynamic>> _rows = [];
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await Db.get();
    final like = '%$_q%';
    final r = await db.query('customers',
        where: _q.isEmpty ? null : 'name LIKE ? OR tin LIKE ? OR phone LIKE ?',
        whereArgs: _q.isEmpty ? null : [like, like, like],
        orderBy: 'name COLLATE NOCASE',
        limit: 500);
    if (mounted) setState(() => _rows = r.map((e) => Map<String, dynamic>.from(e)).toList());
  }

  Future<void> _edit([Map<String, dynamic>? c]) async {
    final saved = await editCustomer(context, c);
    if (saved != null) {
      if (widget.pick && c == null) {
        if (mounted) Navigator.of(context).pop(saved);
        return;
      }
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.pick ? 'Choose customer' : 'Customers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('New customer'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          child: TextField(
            decoration: field('Search name, PIN or phone', prefix: const Icon(Icons.search_rounded)),
            onChanged: (v) {
              _q = v.trim();
              _load();
            },
          ),
        ),
        Expanded(
          child: _rows.isEmpty
              ? const EmptyNote(Icons.people_outline_rounded, 'No customers yet.')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 90),
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final c = _rows[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => widget.pick ? Navigator.of(context).pop(c) : _edit(c),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: card(14),
                        child: Row(children: [
                          CircleAvatar(
                            backgroundColor: C.brandLight,
                            child: Text('${c['name']}'.isEmpty ? '?' : '${c['name']}'.substring(0, 1).toUpperCase(),
                                style: h(16, color: C.brand)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${c['name']}', style: h(15, w: FontWeight.w700)),
                              Text([
                                if ('${c['tin']}'.isNotEmpty) 'PIN ${c['tin']}',
                                if ('${c['phone']}'.isNotEmpty) '${c['phone']}',
                              ].join(' · '), style: const TextStyle(color: C.muted)),
                            ]),
                          ),
                          if (widget.pick) const Icon(Icons.chevron_right_rounded, color: C.muted)
                          else IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(c)),
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

/// Add or edit a customer. Returns the saved row, or null.
Future<Map<String, dynamic>?> editCustomer(BuildContext context, [Map<String, dynamic>? c]) async {
  final name = TextEditingController(text: '${c?['name'] ?? ''}');
  final tin = TextEditingController(text: '${c?['tin'] ?? ''}');
  final phone = TextEditingController(text: '${c?['phone'] ?? ''}');
  final email = TextEditingController(text: '${c?['email'] ?? ''}');
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(c == null ? 'New customer' : 'Edit customer', style: h(19)),
          const SizedBox(height: 14),
          TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: field('Name')),
          const SizedBox(height: 12),
          TextField(
              controller: tin,
              textCapitalization: TextCapitalization.characters,
              decoration: field('KRA PIN (optional)', help: 'Needed for the customer to claim VAT.')),
          const SizedBox(height: 12),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: field('Phone (optional)')),
          const SizedBox(height: 12),
          TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: field('Email (optional)')),
          const SizedBox(height: 16),
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: () async {
                final pin = tin.text.trim().toUpperCase();
                String? err;
                if (name.text.trim().isEmpty) err = 'Enter the name.';
                if (pin.isNotEmpty && !RegExp(r'^[A-Z]\d{9}[A-Z]$').hasMatch(pin)) err = 'The KRA PIN looks wrong (letter, 9 digits, letter).';
                if (err != null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(err)));
                  return;
                }
                final row = <String, dynamic>{
                  'name': name.text.trim(),
                  'tin': pin,
                  'phone': phone.text.trim(),
                  'email': email.text.trim(),
                };
                final db = await Db.get();
                if (c == null) {
                  row['created_at'] = DateTime.now().toIso8601String();
                  row['id'] = await db.insert('customers', row);
                } else {
                  await db.update('customers', row, where: 'id = ?', whereArgs: [c['id']]);
                  row['id'] = c['id'];
                }
                if (ctx.mounted) Navigator.pop(ctx, row);
              },
              child: const Text('Save customer'),
            ),
          ),
        ]),
      ),
    ),
  );
}

/// Remember the customer typed at checkout: match by KRA PIN, else by name
/// (and phone); add them if new, fill in anything missing if known.
Future<void> rememberCustomer({required String name, String tin = '', String phone = ''}) async {
  final nm = name.trim(), pin = tin.trim().toUpperCase(), ph = phone.trim();
  if (nm.isEmpty && pin.isEmpty) return;
  final db = await Db.get();
  List<Map<String, Object?>> hit = const [];
  if (pin.isNotEmpty) {
    hit = await db.query('customers', where: 'tin = ?', whereArgs: [pin], limit: 1);
  }
  if (hit.isEmpty && nm.isNotEmpty) {
    hit = await db.query('customers',
        where: ph.isEmpty ? 'name = ? COLLATE NOCASE' : 'name = ? COLLATE NOCASE AND (phone = ? OR phone = \'\')',
        whereArgs: ph.isEmpty ? [nm] : [nm, ph],
        limit: 1);
  }
  if (hit.isEmpty) {
    await db.insert('customers', {
      'name': nm.isEmpty ? pin : nm,
      'tin': pin,
      'phone': ph,
      'email': '',
      'created_at': DateTime.now().toIso8601String(),
    });
    return;
  }
  final c = hit.first;
  final upd = <String, Object?>{
    if (nm.isNotEmpty && '${c['name']}' != nm) 'name': nm,
    if (pin.isNotEmpty && '${c['tin'] ?? ''}' != pin) 'tin': pin,
    if (ph.isNotEmpty && '${c['phone'] ?? ''}' != ph) 'phone': ph,
  };
  if (upd.isNotEmpty) await db.update('customers', upd, where: 'id = ?', whereArgs: [c['id']]);
}
