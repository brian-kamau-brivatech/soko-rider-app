import 'package:flutter/material.dart';
import '../db.dart';
import '../session.dart';
import '../ui.dart';

/// Change your own username and/or password.
class ChangeCredentialsScreen extends StatefulWidget {
  final Map<String, dynamic> user;
  const ChangeCredentialsScreen({super.key, required this.user});
  @override
  State<ChangeCredentialsScreen> createState() => _ChangeCredentialsScreenState();
}

class _ChangeCredentialsScreenState extends State<ChangeCredentialsScreen> {
  late final _username = TextEditingController(text: '${widget.user['username']}');
  late final _name = TextEditingController(text: '${widget.user['name']}');
  final _current = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  bool _busy = false;

  Future<void> _save() async {
    if (_pass.text.isNotEmpty && _pass.text != _pass2.text) {
      toast(context, 'The new passwords do not match.');
      return;
    }
    if (_current.text.isEmpty) {
      toast(context, 'Enter your current password to confirm.');
      return;
    }
    setState(() => _busy = true);
    final ok = await Session.verify('${widget.user['username']}', _current.text);
    if (ok == null) {
      if (mounted) setState(() => _busy = false);
      if (mounted) toast(context, 'The current password is wrong.');
      return;
    }
    final err = await Session.saveUser(
      id: widget.user['id'] as int,
      username: _username.text,
      name: _name.text,
      role: '${widget.user['role']}',
      password: _pass.text.isEmpty ? null : _pass.text,
      firstLogin: false,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      toast(context, err);
      return;
    }
    toast(context, 'Saved. Use the new details next time you sign in.');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Username & password')),
      body: ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 30), children: [
        Section('Account', [
          Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: TextField(controller: _username, autocorrect: false, decoration: field('Username'))),
          Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: field('Your name (prints on receipts)'))),
        ]),
        Section('New password (leave empty to keep)', [
          Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: TextField(controller: _pass, obscureText: true, decoration: field('New password', help: 'At least 6 characters.'))),
          Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: TextField(controller: _pass2, obscureText: true, decoration: field('Repeat new password'))),
        ]),
        Section('Confirm', [
          Padding(
              padding: const EdgeInsets.all(14),
              child: TextField(controller: _current, obscureText: true, decoration: field('Current password'))),
        ]),
        SizedBox(height: 52, child: FilledButton(onPressed: _busy ? null : _save, child: const Text('Save'))),
      ]),
    );
  }
}

/// Admin: add cashiers and admins, reset passwords, disable accounts.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});
  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await Db.get();
    final r = await db.query('users', orderBy: 'active DESC, role, name COLLATE NOCASE');
    if (mounted) setState(() => _rows = r.map((e) => Map<String, dynamic>.from(e)).toList());
  }

  Future<void> _edit([Map<String, dynamic>? u]) async {
    final username = TextEditingController(text: '${u?['username'] ?? ''}');
    final name = TextEditingController(text: '${u?['name'] ?? ''}');
    final pass = TextEditingController();
    var role = '${u?['role'] ?? 'cashier'}';
    var active = (u?['active'] ?? 1) == 1;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(u == null ? 'New user' : 'Edit ${u['name']}', style: h(19)),
              const SizedBox(height: 14),
              TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: field('Full name')),
              const SizedBox(height: 12),
              TextField(controller: username, autocorrect: false, decoration: field('Username')),
              const SizedBox(height: 12),
              TextField(
                controller: pass,
                obscureText: true,
                decoration: field(u == null ? 'Password' : 'New password (leave empty to keep)',
                    help: u == null ? 'They will be asked to change it at first sign-in.' : null),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'cashier', label: Text('Cashier'), icon: Icon(Icons.point_of_sale_rounded)),
                  ButtonSegment(value: 'admin', label: Text('Admin'), icon: Icon(Icons.admin_panel_settings_rounded)),
                ],
                selected: {role},
                onSelectionChanged: (v) => set(() => role = v.first),
              ),
              const SizedBox(height: 6),
              Text(role == 'admin'
                  ? 'Admins can do everything: settings, items, users, credit notes and closing the day.'
                  : 'Cashiers sell, reprint receipts, see reports and manage customers.',
                  style: const TextStyle(color: C.muted, fontSize: 12.5)),
              if (u != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active (can sign in)'),
                  value: active,
                  onChanged: (v) => set(() => active = v),
                ),
              const SizedBox(height: 12),
              SizedBox(
                height: 50,
                child: FilledButton(
                  onPressed: () async {
                    final err = await Session.saveUser(
                      id: u?['id'] as int?,
                      username: username.text,
                      name: name.text,
                      role: role,
                      password: pass.text.isEmpty ? null : pass.text,
                      active: active,
                      firstLogin: pass.text.isEmpty ? null : true,
                    );
                    if (!ctx.mounted) return;
                    if (err != null) {
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(err)));
                    } else {
                      Navigator.pop(ctx, true);
                    }
                  },
                  child: const Text('Save'),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    if (saved == true) {
      _load();
      if (mounted) toast(context, 'Saved.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Users')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('New user'),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 90), children: [
        Section('Accounts', [
          for (var i = 0; i < _rows.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: _rows[i]['role'] == 'admin' ? C.goldLight : C.brandLight,
                child: Icon(_rows[i]['role'] == 'admin' ? Icons.admin_panel_settings_rounded : Icons.person_rounded,
                    color: _rows[i]['role'] == 'admin' ? C.goldDark : C.brand),
              ),
              title: Text('${_rows[i]['name']}', style: h(15, w: FontWeight.w700, color: _rows[i]['active'] == 1 ? C.ink : C.muted)),
              subtitle: Text('${_rows[i]['username']} · ${_rows[i]['role']}${_rows[i]['active'] == 1 ? '' : ' · disabled'}'),
              trailing: _rows[i]['id'] == Session.i.userId ? const Pill('You', fg: C.brand, bg: C.brandLight) : null,
              onTap: () => _edit(_rows[i]),
            ),
          ],
        ]),
      ]),
    );
  }
}
