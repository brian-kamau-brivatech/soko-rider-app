import 'package:flutter/material.dart';
import '../db.dart';
import '../fmt.dart';
import '../perms.dart';
import '../session.dart';
import '../ui.dart';

class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});
  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.q('SELECT u.*, r.name AS role FROM users u LEFT JOIN roles r ON r.id = u.role_id ORDER BY u.active DESC, u.owner DESC, u.name');
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _open([int? id]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserForm(id: id)));
    _load();
    Session.i.reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Users'), actions: [
          if (Session.i.can(P.roles))
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RolesScreen())),
              icon: const Icon(Icons.admin_panel_settings_outlined),
              label: const Text('Roles'),
            ),
        ]),
        floatingActionButton: FloatingActionButton.extended(onPressed: () => _open(), icon: const Icon(Icons.person_add_alt), label: const Text('User')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 90), children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Text('Everyone gets their own PIN. What they can do comes from their role.', style: muted),
          ),
          for (final u in _rows)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: box(),
              child: ListTile(
                leading: Avatar(s(u['name']), size: 42, bg: n(u['active']) == 1 ? C.ink : C.soft, fg: n(u['active']) == 1 ? Colors.white : C.muted),
                title: Text(s(u['name']), style: TextStyle(fontWeight: FontWeight.w700, color: n(u['active']) == 1 ? C.text : C.muted)),
                subtitle: Text('${n(u['owner']) == 1 ? 'Owner' : s(u['role'])}${n(u['active']) == 1 ? '' : ' · disabled'}${s(u['last_login']).isEmpty ? '' : ' · last in ${dateText(u['last_login'])}'}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(n(u['id'])),
              ),
            ),
        ]),
      );
}

class UserForm extends StatefulWidget {
  final int? id;
  const UserForm({super.key, this.id});
  @override
  State<UserForm> createState() => _UserFormState();
}

class _UserFormState extends State<UserForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _pin = TextEditingController();
  List<Map<String, Object?>> _roles = [];
  int? _role;
  bool _active = true;
  bool _owner = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.q('SELECT * FROM roles ORDER BY system DESC, name');
    Map<String, Object?>? u;
    if (widget.id != null) u = await Db.one('SELECT * FROM users WHERE id = ?', [widget.id]);
    if (!mounted) return;
    setState(() {
      _roles = r;
      final cashier = r.where((x) => s(x['name']) == 'Cashier').toList();
      _role = cashier.isNotEmpty ? n(cashier.first['id']) : (r.isEmpty ? null : n(r.first['id']));
      if (u != null) {
        _name.text = s(u['name']);
        _phone.text = s(u['phone']);
        _role = n(u['role_id']);
        _active = n(u['active']) == 1;
        _owner = n(u['owner']) == 1;
      }
    });
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _role == null) {
      toast(context, 'Enter the name and choose the role.');
      return;
    }
    final pin = _pin.text.trim();
    if (widget.id == null || pin.isNotEmpty) {
      if (!Session.pinOk(pin)) {
        toast(context, 'The PIN must be 4 to 6 digits.');
        return;
      }
      if (await Session.pinTaken(pin, exceptId: widget.id ?? 0)) {
        if (mounted) toast(context, 'Someone else already uses this PIN. Choose another.');
        return;
      }
    }
    final db = await Db.get();
    if (widget.id == null) {
      await Session.createUser(name: _name.text.trim(), pin: pin, roleId: _role!, phone: _phone.text.trim());
      await Db.audit(db, Session.i.userId, 'user_add', _name.text.trim());
    } else {
      if (_owner && !_active) {
        if (mounted) toast(context, 'The owner cannot be disabled.');
        return;
      }
      await db.update('users', {'name': _name.text.trim(), 'phone': _phone.text.trim(), 'role_id': _owner ? null : _role, 'active': _active ? 1 : 0}..removeWhere((k, v) => k == 'role_id' && v == null),
          where: 'id = ?', whereArgs: [widget.id]);
      if (pin.isNotEmpty) await Session.setPin(widget.id!, pin);
      await Db.audit(db, Session.i.userId, 'user_edit', '${_name.text.trim()}${pin.isNotEmpty ? ' (PIN changed)' : ''}');
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.id == null ? 'New user' : 'Edit user')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name *')),
          const SizedBox(height: 10),
          TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
          const SizedBox(height: 10),
          if (_owner)
            const ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.verified_user_outlined), title: Text('Owner'), subtitle: Text('Has every right. Cannot be removed.'))
          else
            DropdownButtonFormField<int>(
              value: _roles.any((r) => n(r['id']) == _role) ? _role : null,
              decoration: const InputDecoration(labelText: 'Role *'),
              items: [for (final r in _roles) DropdownMenuItem(value: n(r['id']), child: Text(s(r['name'])))],
              onChanged: (v) => setState(() => _role = v),
            ),
          const SizedBox(height: 10),
          TextField(
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: InputDecoration(
              labelText: widget.id == null ? 'PIN (4-6 digits) *' : 'New PIN (leave empty to keep)',
              helperText: 'Tell the person their PIN; they use it to sign in.',
              counterText: '',
            ),
          ),
          if (widget.id != null && !_owner)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('Active'),
              subtitle: const Text('Off: the person can no longer sign in (their sales stay).'),
            ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ]),
      );
}

class RolesScreen extends StatefulWidget {
  const RolesScreen({super.key});
  @override
  State<RolesScreen> createState() => _RolesScreenState();
}

class _RolesScreenState extends State<RolesScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.q('SELECT r.*, (SELECT COUNT(*) FROM users u WHERE u.role_id = r.id AND u.active = 1) AS users FROM roles r ORDER BY system DESC, name');
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _open([Map<String, Object?>? r]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RoleForm(role: r)));
    _load();
    Session.i.reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Roles and rights')),
        floatingActionButton: FloatingActionButton.extended(onPressed: () => _open(), icon: const Icon(Icons.add), label: const Text('Role')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 90), children: [
          for (final r in _rows)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: box(),
              child: ListTile(
                title: Text(s(r['name']), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${s(r['perms']).split(',').where((x) => x.isNotEmpty).length} rights · ${n(r['users'])} users'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(r),
              ),
            ),
        ]),
      );
}

class RoleForm extends StatefulWidget {
  final Map<String, Object?>? role;
  const RoleForm({super.key, this.role});
  @override
  State<RoleForm> createState() => _RoleFormState();
}

class _RoleFormState extends State<RoleForm> {
  late final _name = TextEditingController(text: s(widget.role?['name']));
  late final Set<String> _perms = s(widget.role?['perms']).split(',').where((x) => x.isNotEmpty).toSet();

  bool get _system => n(widget.role?['system']) == 1;

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      toast(context, 'Enter the role name.');
      return;
    }
    final db = await Db.get();
    final vals = {'name': _name.text.trim(), 'perms': P.keys.where(_perms.contains).join(',')};
    if (widget.role == null) {
      await Db.ins(db, 'roles', vals);
    } else {
      await db.update('roles', vals, where: 'id = ?', whereArgs: [widget.role!['id']]);
    }
    await Db.audit(db, Session.i.userId, 'role_save', '${vals['name']}: ${vals['perms']}');
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final used = await Db.count('SELECT COUNT(*) FROM users WHERE role_id = ?', [widget.role!['id']]);
    if (!mounted) return;
    if (used > 0) {
      toast(context, 'Move its $used users to another role first.');
      return;
    }
    if (!await confirm(context, 'Delete role?', s(widget.role!['name']), ok: 'Delete', danger: true)) return;
    final db = await Db.get();
    await db.delete('roles', where: 'id = ?', whereArgs: [widget.role!['id']]);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String>[];
    for (final p in P.all) {
      if (!groups.contains(p.$3)) groups.add(p.$3);
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.role == null ? 'New role' : 'Role'), actions: [
        if (widget.role != null && !_system) IconButton(onPressed: _delete, icon: const Icon(Icons.delete_outline)),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        TextField(controller: _name, readOnly: _system, decoration: const InputDecoration(labelText: 'Role name')),
        if (_system) const Padding(padding: EdgeInsets.only(top: 8), child: Text('The Owner role always has every right.', style: muted)),
        const SizedBox(height: 12),
        for (final g in groups)
          Group(g, [
            for (final p in P.all.where((x) => x.$3 == g))
              CheckboxListTile(
                dense: true,
                value: _system || _perms.contains(p.$1),
                onChanged: _system ? null : (v) => setState(() => v == true ? _perms.add(p.$1) : _perms.remove(p.$1)),
                title: Text(p.$2),
              ),
          ]),
        if (!_system) FilledButton(onPressed: _save, child: const Text('Save role')),
      ]),
    );
  }
}
