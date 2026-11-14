import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../fmt.dart';
import '../net.dart';
import '../ui.dart';

/// BRV Licence: the developer's app. Companies, licence days, number of user devices, device codes.
class DevApp extends StatelessWidget {
  const DevApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'BRV Licence',
        debugShowCheckedModeBanner: false,
        theme: appTheme(),
        home: const _Start(),
      );
}

class Dev {
  static String server = defaultServer;
  static String key = '';

  static Future<Map<String, dynamic>> call(String method, String path, {Map<String, dynamic>? body}) =>
      Net.call(server, method, '/dev$path', body: body, headers: {'X-Dev-Key': key});
}

class _Start extends StatefulWidget {
  const _Start();
  @override
  State<_Start> createState() => _StartState();
}

class _StartState extends State<_Start> {
  bool _ready = false;
  bool _signedIn = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      Dev.server = defaultServer;
      Dev.key = p.getString('dev_key') ?? '';
      setState(() {
        _ready = true;
        _signedIn = Dev.key.isNotEmpty;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return _signedIn ? CompaniesScreen(onSignOut: () => setState(() => _signedIn = false)) : _Login(onDone: () => setState(() => _signedIn = true));
  }
}

class _Login extends StatefulWidget {
  final VoidCallback onDone;
  const _Login({required this.onDone});
  @override
  State<_Login> createState() => _LoginState();
}

class _LoginState extends State<_Login> {
  final _key = TextEditingController();
  bool _busy = false;

  Future<void> _go() async {
    setState(() => _busy = true);
    Dev.key = _key.text.trim();
    try {
      await Dev.call('GET', '/companies');
      final p = await SharedPreferences.getInstance();
      await p.setString('dev_key', Dev.key);
      widget.onDone();
    } on NetError catch (e) {
      if (mounted) toast(context, e.status == 401 ? 'Wrong developer key.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(22, 40, 22, 24), children: [
            Center(child: Image.asset('assets/brv_logo.png', height: 120)),
            const SizedBox(height: 10),
            Center(child: Text('BRV Licence', style: h(26))),
            const Center(child: Text('Developer: companies, licences and devices', style: muted)),
            const SizedBox(height: 24),
            TextField(controller: _key, obscureText: true, decoration: const InputDecoration(labelText: 'Developer key')),
            const SizedBox(height: 18),
            FilledButton(onPressed: _busy ? null : _go, child: Text(_busy ? 'Checking...' : 'Sign in')),
          ]),
        ),
      );
}

Color _daysColor(int d, bool active) => !active ? C.muted : (d <= 0 ? C.red : (d <= 7 ? C.amber : C.green));

class CompaniesScreen extends StatefulWidget {
  final VoidCallback onSignOut;
  const CompaniesScreen({super.key, required this.onSignOut});
  @override
  State<CompaniesScreen> createState() => _CompaniesScreenState();
}

class _CompaniesScreenState extends State<CompaniesScreen> {
  List<Map<String, dynamic>> _rows = [];
  String _error = '';
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Dev.call('GET', '/companies');
      _rows = ((r['companies'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      _error = '';
    } on NetError catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() {});
  }

  Future<void> _new() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final days = TextEditingController(text: '365');
    final devices = TextEditingController(text: '2');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New company'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Company name')),
            const SizedBox(height: 8),
            TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
            const SizedBox(height: 8),
            TextField(controller: days, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Licence days')),
            const SizedBox(height: 8),
            TextField(controller: devices, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'User devices allowed (besides the manager)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(minimumSize: const Size(0, 42)), child: const Text('Create')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    try {
      final r = await Dev.call('POST', '/companies', body: {
        'name': name.text.trim(), 'phone': phone.text.trim(), 'days': int.tryParse(days.text.trim()) ?? 0,
        'max_devices': int.tryParse(devices.text.trim()) ?? 2,
      });
      await _load();
      if (!mounted) return;
      final c = Map<String, dynamic>.from(r['company'] as Map);
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CompanyScreen(id: (c['id'] as num).toInt())));
      _load();
    } on NetError catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = _rows.where((c) => q.isEmpty || '${c['name']}'.toLowerCase().contains(q) || '${c['phone']}'.contains(q)).toList();
    final active = _rows.where((c) => c['active'] == true && (c['days_left'] as num) > 0).length;
    final soon = _rows.where((c) => c['active'] == true && (c['days_left'] as num) > 0 && (c['days_left'] as num) <= 14).length;
    return Scaffold(
      appBar: AppBar(title: const Text('BRV Licence'), actions: [
        IconButton(
          tooltip: 'Devices waiting',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WaitingScreen())),
          icon: const Icon(Icons.qr_code_2),
        ),
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        IconButton(
          onPressed: () async {
            final p = await SharedPreferences.getInstance();
            await p.remove('dev_key');
            Dev.key = '';
            widget.onSignOut();
          },
          icon: const Icon(Icons.logout),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: _new, icon: const Icon(Icons.add_business), label: const Text('Company')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 90), children: [
          Row(children: [
            Expanded(child: StatTile(dark: true, value: '${_rows.length}', label: 'Companies', progress: _rows.isEmpty ? 0 : active / _rows.length, note: '$active active')),
            const SizedBox(width: 12),
            Expanded(child: StatTile(value: '$soon', label: 'Ending in 14 days', progress: _rows.isEmpty ? 0 : soon / _rows.length, note: 'to renew', bar: C.pink)),
          ]),
          const SizedBox(height: 14),
          TextField(decoration: const InputDecoration(hintText: 'Search company', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => _q = v)),
          const SizedBox(height: 10),
          if (_error.isNotEmpty) Empty(Icons.cloud_off, _error),
          for (final c in shown)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: box(),
              child: ListTile(
                leading: Avatar('${c['name']}', size: 44, bg: C.ink, fg: Colors.white),
                title: Text('${c['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${c['devices_used']} of ${c['max_devices']} user devices · ${c['has_manager'] == true ? 'manager active' : 'no manager yet'}'),
                trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(c['active'] == true ? '${c['days_left']} days' : 'Suspended',
                      style: h(14, color: _daysColor((c['days_left'] as num).toInt(), c['active'] == true))),
                  Text(dateText(DateTime.tryParse('${c['expires_at']}')?.toLocal().toIso8601String(), time: false), style: muted),
                ]),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CompanyScreen(id: (c['id'] as num).toInt())));
                  _load();
                },
              ),
            ),
        ]),
      ),
    );
  }
}

class CompanyScreen extends StatefulWidget {
  final int id;
  const CompanyScreen({super.key, required this.id});
  @override
  State<CompanyScreen> createState() => _CompanyScreenState();
}

class _CompanyScreenState extends State<CompanyScreen> {
  Map<String, dynamic>? _c;
  List<Map<String, dynamic>> _devices = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _use(Map<String, dynamic> r) {
    if (r['company'] is Map) _c = Map<String, dynamic>.from(r['company'] as Map);
    if (r['devices'] is List) _devices = (r['devices'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> _load() async {
    try {
      _use(await Dev.call('GET', '/companies/${widget.id}'));
    } on NetError catch (e) {
      if (mounted) toast(context, e.message);
    }
    if (mounted) setState(() {});
  }

  Future<void> _patch(Map<String, dynamic> body, String done) async {
    try {
      _use(await Dev.call('PATCH', '/companies/${widget.id}', body: body));
      if (mounted) toast(context, done);
    } on NetError catch (e) {
      if (mounted) toast(context, e.message);
    }
    if (mounted) setState(() {});
  }

  Future<void> _bind(String role) async {
    final w = await Dev.call('GET', '/waiting').catchError((_) => <String, dynamic>{'waiting': []});
    final waiting = ((w['waiting'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).where((e) => e['app'] == role).toList();
    if (!mounted) return;
    String? code;
    if (waiting.isNotEmpty) {
      code = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text(role == 'manager' ? 'Manager phones waiting' : 'User devices waiting', style: h(17))),
            for (final x in waiting)
              ListTile(
                leading: const Icon(Icons.smartphone),
                title: Text(_shown('${x['code']}'), style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
                subtitle: Text('${x['model']} · ${dateText(DateTime.tryParse('${x['last_seen']}')?.toLocal().toIso8601String())}'),
                onTap: () => Navigator.pop(ctx, '${x['code']}'),
              ),
            ListTile(leading: const Icon(Icons.keyboard), title: const Text('Type a code'), onTap: () => Navigator.pop(ctx, '')),
          ]),
        ),
      );
      if (code == null || !mounted) return;
    }
    if (code == null || code.isEmpty) {
      code = await ask(context, role == 'manager' ? 'Manager device code' : 'User device code', label: 'Code shown on the device');
      if (code == null || code.trim().isEmpty) return;
    }
    try {
      _use(await Dev.call('POST', '/companies/${widget.id}/bind', body: {'code': code.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase(), 'role': role}));
      if (mounted) toast(context, role == 'manager' ? 'Manager activated. The phone opens by itself.' : 'Device added.');
    } on NetError catch (e) {
      if (mounted) toast(context, e.message);
    }
    if (mounted) setState(() {});
  }

  Future<void> _addDays() async {
    final v = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('Add licence days', style: h(17))),
          for (final dd in [30, 90, 180, 365]) ListTile(title: Text('+ $dd days'), onTap: () => Navigator.pop(ctx, dd)),
          ListTile(title: const Text('Other number...'), onTap: () => Navigator.pop(ctx, -1)),
        ]),
      ),
    );
    if (v == null || !mounted) return;
    var days = v;
    if (v == -1) {
      final t = int.tryParse((await ask(context, 'Add days', number: true)) ?? '');
      if (t == null || t == 0) return;
      days = t;
    }
    await _patch({'add_days': days}, 'Added $days days.');
  }

  /// Forgotten PIN: choose the user, set a new PIN; the manager phone applies it at its next sync.
  Future<void> _pinReset() async {
    List<Map<String, dynamic>> users;
    try {
      final r = await Dev.call('GET', '/companies/${widget.id}/users');
      users = ((r['users'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on NetError catch (e) {
      if (mounted) toast(context, e.message);
      return;
    }
    if (!mounted) return;
    if (users.isEmpty) {
      toast(context, 'No users yet. The manager phone sends its users when it syncs.');
      return;
    }
    final u = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text('Reset whose PIN?', style: h(17))),
          for (final x in users)
            ListTile(
              leading: Icon(x['owner'] == true ? Icons.star : Icons.person_outline, color: x['active'] == true ? C.ink : C.muted),
              title: Text('${x['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text([
                if ('${x['role'] ?? ''}'.isNotEmpty) '${x['role']}',
                if (x['active'] != true) 'inactive',
                if (x['reset_pending'] == true) 'reset waiting for the phone',
              ].join(' · ')),
              onTap: () => Navigator.pop(ctx, x),
            ),
        ]),
      ),
    );
    if (u == null || !mounted) return;
    final p1 = await ask(context, 'New PIN for ${u['name']}', label: '4 to 6 digits', number: true);
    if (p1 == null || !mounted) return;
    if (!RegExp(r'^\d{4,6}$').hasMatch(p1.trim())) {
      toast(context, 'The PIN must be 4 to 6 digits.');
      return;
    }
    final p2 = await ask(context, 'Type the PIN again', number: true);
    if (p2 == null || !mounted) return;
    if (p2.trim() != p1.trim()) {
      toast(context, 'The two PINs are different.');
      return;
    }
    try {
      await Dev.call('POST', '/companies/${widget.id}/pin_reset', body: {'user_id': u['id'], 'pin': p1.trim()});
      if (mounted) toast(context, 'Done. The manager phone applies the new PIN at its next sync (open it while online).');
    } on NetError catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  String _shown(String code) => code.length == 12 ? '${code.substring(0, 4)}-${code.substring(4, 8)}-${code.substring(8)}' : code;

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final days = (c['days_left'] as num).toInt();
    final active = c['active'] == true;
    final maxD = (c['max_devices'] as num).toInt();
    return Scaffold(
      appBar: AppBar(title: Text('${c['name']}'), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: box(color: C.ink, border: false),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(active ? '$days days left' : 'Suspended', style: h(30, color: active ? (days <= 7 ? C.pink : C.gold) : Colors.white)),
              Text('Until ${dateText(DateTime.tryParse('${c['expires_at']}')?.toLocal().toIso8601String(), time: false)}',
                  style: const TextStyle(color: Color(0xFFCBD5E1))),
              const SizedBox(height: 10),
              Text('${c['devices_used']} of $maxD user devices · ${c['has_manager'] == true ? 'manager active' : 'no manager yet'}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              if ('${c['phone']}'.isNotEmpty) Text('${c['phone']}', style: const TextStyle(color: Color(0xFFCBD5E1))),
            ]),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: _addDays, icon: const Icon(Icons.add), label: const Text('Add days'))),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton.icon(onPressed: () => _bind('manager'), icon: const Icon(Icons.admin_panel_settings_outlined), label: const Text('Manager code'))),
          ]),
          const SizedBox(height: 14),
          Container(
            decoration: box(),
            child: Column(children: [
              ListTile(
                title: const Text('User devices allowed'),
                subtitle: const Text('BRV Pos Sales devices the manager can add'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(onPressed: maxD <= 0 ? null : () => _patch({'max_devices': maxD - 1}, 'Limit: ${maxD - 1}'), icon: const Icon(Icons.remove_circle_outline)),
                  Text('$maxD', style: h(18)),
                  IconButton(onPressed: () => _patch({'max_devices': maxD + 1}, 'Limit: ${maxD + 1}'), icon: const Icon(Icons.add_circle_outline)),
                ]),
              ),
              const Divider(),
              SwitchListTile(
                value: active,
                onChanged: (v) => _patch({'active': v}, v ? 'Licence active.' : 'Licence suspended: devices stop at their next sync.'),
                title: const Text('Licence active'),
                subtitle: const Text('Off = suspended (e.g. not paid)'),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.event),
                title: const Text('Set exact days from today'),
                onTap: () async {
                  final t = int.tryParse((await ask(context, 'Days from today', number: true, initial: '$days')) ?? '');
                  if (t != null) await _patch({'set_days': t}, 'Licence set to $t days.');
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Name and phone'),
                onTap: () async {
                  final nm = await ask(context, 'Company name', initial: '${c['name']}');
                  if (nm == null || !mounted) return;
                  final ph = await ask(context, 'Phone', initial: '${c['phone']}');
                  await _patch({'name': nm.trim(), 'phone': (ph ?? '${c['phone']}').trim()}, 'Saved.');
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.lock_reset),
                title: const Text("Reset a user's PIN"),
                subtitle: const Text('For a manager who forgot the PIN'),
                onTap: _pinReset,
              ),
            ]),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: Text('Devices', style: h(17))),
            TextButton.icon(onPressed: () => _bind('sales'), icon: const Icon(Icons.add), label: const Text('User device')),
          ]),
          if (_devices.isEmpty) const Empty(Icons.smartphone, 'No devices yet. Activate the manager phone with its code.'),
          for (final d in _devices)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: box(),
              child: ListTile(
                leading: Icon(d['role'] == 'manager' ? Icons.admin_panel_settings : Icons.point_of_sale, color: d['active'] == true ? C.ink : C.muted),
                title: Text('${d['name']} · no. ${d['device_no']}', style: TextStyle(fontWeight: FontWeight.w700, color: d['active'] == true ? C.text : C.muted)),
                subtitle: Text('${_shown('${d['code']}')} · ${d['model']}\nLast sync: ${d['last_sync'] == null ? 'never' : dateText(DateTime.tryParse('${d['last_sync']}')?.toLocal().toIso8601String())}'),
                isThreeLine: true,
                trailing: Switch(
                  value: d['active'] == true,
                  onChanged: (v) async {
                    try {
                      _use(await Dev.call('POST', '/devices/${d['id']}', body: {'active': v}));
                      await _load();
                    } on NetError catch (e) {
                      if (context.mounted) toast(context, e.message);
                    }
                  },
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

class WaitingScreen extends StatefulWidget {
  const WaitingScreen({super.key});
  @override
  State<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<WaitingScreen> {
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Dev.call('GET', '/waiting');
      _rows = ((r['waiting'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on NetError catch (e) {
      if (mounted) toast(context, e.message);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Devices waiting'), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
        body: _rows.isEmpty
            ? const Empty(Icons.qr_code_2, 'No device is waiting. Open the Manager or Sales app on the device (with internet) to show its code.')
            : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                for (final x in _rows)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: box(),
                    child: ListTile(
                      leading: Icon(x['app'] == 'manager' ? Icons.admin_panel_settings : Icons.point_of_sale),
                      title: Text('${x['code']}', style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
                      subtitle: Text('${x['app'] == 'manager' ? 'Manager app' : 'Sales app'} · ${x['model']} · '
                          '${dateText(DateTime.tryParse('${x['last_seen']}')?.toLocal().toIso8601String())}'),
                    ),
                  ),
              ]),
      );
}
