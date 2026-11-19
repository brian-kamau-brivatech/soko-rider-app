import 'dart:convert';
import 'package:flutter/material.dart';
import '../bus.dart';
import '../db.dart';
import '../fmt.dart';
import '../sales.dart' show SaleError;
import '../screens/sales_screen.dart' show SaleDetail;
import '../settings.dart';
import '../ui.dart';
import 'etr.dart';

/// More > KRA eTIMS device: status, invoices waiting for KRA, item registration, and the technician set-up.
class EtrScreen extends StatefulWidget {
  const EtrScreen({super.key});
  @override
  State<EtrScreen> createState() => _EtrScreenState();
}

class _EtrScreenState extends State<EtrScreen> {
  List<Map<String, Object?>> _open = [];
  int _next = 1, _unreg = 0, _classes = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final o = await Db.q(
        "SELECT e.*, s.number, s.total FROM etr_sales e LEFT JOIN sales s ON s.id = e.id WHERE e.status IN ('pending', 'failed') "
        'AND e.device_no = ? ORDER BY e.id',
        [Db.deviceNo]);
    final nx = await Etr.nextInvoice();
    final u = await Db.count('SELECT COUNT(*) FROM products WHERE active = 1 AND kra_reg = 0');
    final c = await Db.count('SELECT COUNT(*) FROM item_classes');
    if (mounted) setState(() { _open = o; _next = nx; _unreg = u; _classes = c; });
  }

  Future<void> _run(Future<String> Function() job) async {
    setState(() => _busy = true);
    try {
      final m = await job();
      if (mounted) toast(context, m);
    } on SaleError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
      changed();
      _load();
    }
  }

  /// The set-up is for the technician: a PIN is made the first time, then asked every time.
  Future<void> _setup() async {
    if (!Etr.hasTechPin) {
      final p1 = await ask(context, 'New technician PIN', label: '4 to 8 digits; it locks the KRA device set-up', number: true);
      if (p1 == null || !mounted) return;
      if (!RegExp(r'^\d{4,8}$').hasMatch(p1.trim())) {
        toast(context, 'Use 4 to 8 digits.');
        return;
      }
      final p2 = await ask(context, 'Type the technician PIN again', number: true);
      if (p2 == null || !mounted) return;
      if (p2.trim() != p1.trim()) {
        toast(context, 'The two PINs are different.');
        return;
      }
      await Etr.setTechPin(p1);
    } else {
      final p = await ask(context, 'Technician PIN', number: true);
      if (p == null || !mounted) return;
      if (!Etr.techOk(p)) {
        toast(context, 'Wrong technician PIN.');
        return;
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EtrSetupScreen()));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = Settings.i;
    final ready = Etr.ready;
    return Scaffold(
      appBar: AppBar(title: const Text('KRA eTIMS device'), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: box(color: C.ink, border: false),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ready ? 'Ready to sign sales' : 'Not set up', style: h(24, color: ready ? C.gold : Colors.white)),
            const SizedBox(height: 6),
            if (Etr.taxpayer.isNotEmpty) Text(Etr.taxpayer, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            Text([
              if (Etr.tin.isNotEmpty) 'PIN ${Etr.tin}',
              'Branch ${Etr.bhfId}${Etr.branch.isEmpty ? '' : ' ${Etr.branch}'}',
              if (Etr.sdcId.isNotEmpty) 'SCU ${Etr.sdcId}',
            ].join(' · '), style: const TextStyle(color: Color(0xFFCBD5E1))),
            const SizedBox(height: 6),
            Text('Next invoice number: $_next', style: const TextStyle(color: Colors.white)),
            if (!ready) const Text('A technician enters the VSCU details and initialises the device below.', style: TextStyle(color: Color(0xFFCBD5E1))),
          ]),
        ),
        if (_open.isNotEmpty) ...[
          const Label('Not signed yet'),
          for (final e in _open)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: box(),
              child: ListTile(
                leading: Icon(s(e['status']) == 'pending' ? Icons.hourglass_top : Icons.error_outline, color: s(e['status']) == 'pending' ? C.amber : C.red),
                title: Text('${s(e['trd_invc_no'])} · ${s(e['number'])}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${s(e['status']) == 'pending' ? 'Waiting for KRA' : 'Refused'} · ${money(d(e['total']).abs())}\n${s(e['error'])}'),
                isThreeLine: true,
                trailing: s(e['status']) == 'pending'
                    ? TextButton(
                        onPressed: _busy ? null : () => _run(() async => await Etr.retry(n(e['id'])) ?? 'Signed by KRA.'),
                        child: const Text('Retry'))
                    : const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SaleDetail(saleId: n(e['id']))));
                  _load();
                },
              ),
            ),
        ],
        const Label('Items'),
        Container(
          decoration: box(),
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.app_registration),
              title: const Text('Register items with KRA'),
              subtitle: Text(_unreg == 0 ? 'All active items are registered.' : '$_unreg not registered yet (done by itself at the first sale too).'),
              trailing: _unreg == 0 ? null : const Icon(Icons.chevron_right),
              onTap: !ready || _busy || _unreg == 0
                  ? null
                  : () => _run(() async {
                        final (ok, bad) = await Etr.registerAll();
                        return bad == 0 ? '$ok items registered.' : '$ok registered, $bad refused. Open the product to see why.';
                      }),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.category_outlined),
              title: const Text('KRA item classes'),
              subtitle: Text(_classes == 0 ? 'Not downloaded yet.' : '$_classes classes on this device.'),
              trailing: const Icon(Icons.download),
              onTap: !ready || _busy ? null : () => _run(() async => (await Etr.refreshItemClasses()).message),
            ),
          ]),
        ),
        const Label('Device'),
        Container(
          decoration: box(),
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Device set-up (technician)'),
              subtitle: const Text('VSCU address, KRA PIN, branch, serial, initialise'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _setup,
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.list_alt),
              title: const Text('VSCU call log'),
              subtitle: const Text('Last 500 requests and answers'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CallsScreen())),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        Text('Business name on receipts: ${st.businessName}', style: muted, textAlign: TextAlign.center),
      ]),
    );
  }
}

class EtrSetupScreen extends StatefulWidget {
  const EtrSetupScreen({super.key});
  @override
  State<EtrSetupScreen> createState() => _EtrSetupScreenState();
}

class _EtrSetupScreenState extends State<EtrSetupScreen> {
  final _url = TextEditingController(text: Etr.url);
  final _tin = TextEditingController(text: Etr.tin);
  final _bhf = TextEditingController(text: Etr.bhfId);
  final _serial = TextEditingController(text: Etr.serial);
  bool _incl = Etr.inclVat;
  String _cls = Etr.defaultClass;
  bool _busy = false;
  int _next = 1;

  @override
  void initState() {
    super.initState();
    Etr.nextInvoice().then((v) {
      if (mounted) setState(() => _next = v);
    });
  }

  Future<bool> _save() async {
    final st = Settings.i;
    final tin = _tin.text.trim().toUpperCase();
    if (_url.text.trim().isEmpty || tin.length != 11 || _serial.text.trim().isEmpty) {
      toast(context, 'Enter the VSCU address, the 11-character KRA PIN and the device serial.');
      return false;
    }
    final changedId = tin != Etr.tin || _bhf.text.trim() != Etr.bhfId || _serial.text.trim() != Etr.serial;
    await st.set('etr_url', _url.text.trim());
    await st.set('etr_tin', tin);
    await st.set('etr_bhf', _bhf.text.trim().isEmpty ? '00' : _bhf.text.trim());
    await st.set('etr_serial', _serial.text.trim());
    await st.setFlag('etr_incl', _incl);
    await st.set('etr_cls', _cls);
    if (changedId) await st.setFlag('etr_init', false); // a new PIN, branch or serial must be initialised again
    return true;
  }

  Future<void> _job(Future<String> Function() f) async {
    setState(() => _busy = true);
    try {
      final m = await f();
      if (mounted) toast(context, m);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('KRA device set-up')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          TextField(controller: _url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'VSCU address', hintText: 'http://192.168.1.10:8088')),
          const SizedBox(height: 10),
          TextField(controller: _tin, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'KRA PIN of the business')),
          const SizedBox(height: 10),
          Row(children: [
            SizedBox(width: 110, child: TextField(controller: _bhf, decoration: const InputDecoration(labelText: 'Branch ID'))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _serial, decoration: const InputDecoration(labelText: 'Device serial (dvcSrlNo)'))),
          ]),
          const SizedBox(height: 6),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Default KRA item class'),
            subtitle: Text(_cls.isEmpty ? 'None: every product needs its own class' : _cls),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final c = await pickItemClass(context, current: _cls);
              if (c != null) setState(() => _cls = c);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _incl,
            onChanged: (v) => setState(() => _incl = v),
            title: const Text('Send line prices VAT inclusive'),
            subtitle: const Text('On for most VSCUs (KRA convention). Change only if KRA asks.'),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _job(() async => (await Etr.ping(_url.text)).$2),
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Test address'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _job(() async {
                          if (!await _save()) return 'Not saved.';
                          final r = await Etr.initialise();
                          final nx = await Etr.nextInvoice();
                          if (mounted) setState(() => _next = nx);
                          return r.ok ? 'Initialised: ${Etr.taxpayer}' : (Etr.initialised ? 'Device already installed at KRA: ready.' : r.message);
                        }),
                icon: const Icon(Icons.power_settings_new),
                label: const Text('Save + initialise'),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    if (await _save() && context.mounted) toast(context, 'Saved.');
                  },
            child: const Text('Save only'),
          ),
          const Label('Invoice numbers'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Next invoice number: $_next'),
            subtitle: const Text('Set by itself from KRA at initialisation. Change only on KRA\'s instruction.'),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () async {
              final v = int.tryParse((await ask(context, 'Next invoice number', number: true, initial: '$_next')) ?? '');
              if (v == null || v < 1) return;
              await Etr.setNextInvoice(v);
              if (mounted) setState(() => _next = v);
            },
          ),
          const Label('Security'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.password),
            title: const Text('Change technician PIN'),
            onTap: () async {
              final p1 = await ask(context, 'New technician PIN', label: '4 to 8 digits', number: true);
              if (p1 == null || !context.mounted) return;
              if (!RegExp(r'^\d{4,8}$').hasMatch(p1.trim())) {
                toast(context, 'Use 4 to 8 digits.');
                return;
              }
              await Etr.setTechPin(p1);
              if (context.mounted) toast(context, 'Technician PIN changed.');
            },
          ),
        ]),
      );
}

/// Choose a KRA item class (from the classes downloaded from the VSCU, or typed).
Future<String?> pickItemClass(BuildContext context, {String current = ''}) async {
  final all = await Db.q('SELECT * FROM item_classes ORDER BY cd');
  if (!context.mounted) return null;
  if (all.isEmpty) {
    final v = await ask(context, 'KRA item class code', initial: current, hint: 'Download the classes in KRA eTIMS device to pick from a list');
    return v?.trim();
  }
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _ClassPicker(all: all),
  );
}

class _ClassPicker extends StatefulWidget {
  final List<Map<String, Object?>> all;
  const _ClassPicker({required this.all});
  @override
  State<_ClassPicker> createState() => _ClassPickerState();
}

class _ClassPickerState extends State<_ClassPicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = widget.all.where((c) => q.isEmpty || s(c['cd']).startsWith(q) || s(c['nm']).toLowerCase().contains(q)).take(200).toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(autofocus: true, decoration: const InputDecoration(hintText: 'Search class name or code', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => _q = v)),
          ),
          Expanded(
            child: ListView(children: [
              for (final c in shown)
                ListTile(
                  title: Text(s(c['nm'])),
                  subtitle: Text('${s(c['cd'])}${s(c['tax']).isEmpty ? '' : ' · tax ${s(c['tax'])}'}'),
                  onTap: () => Navigator.pop(context, s(c['cd'])),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class CallsScreen extends StatefulWidget {
  const CallsScreen({super.key});
  @override
  State<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends State<CallsScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    Db.q('SELECT * FROM etr_calls ORDER BY id DESC LIMIT 200').then((r) {
      if (mounted) setState(() => _rows = r);
    });
  }

  String _pretty(String j) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(j));
    } catch (_) {
      return j;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('VSCU call log')),
        body: _rows.isEmpty
            ? const Empty(Icons.list_alt, 'No calls yet.')
            : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                for (final r in _rows)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: box(),
                    child: ExpansionTile(
                      leading: Icon(n(r['ok']) == 1 ? Icons.check_circle_outline : Icons.error_outline, color: n(r['ok']) == 1 ? C.green : C.red),
                      title: Text(s(r['path']), style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${dateText(r['at'])} · ${s(r['code'])} ${s(r['msg'])} · ${r['ms']} ms'),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText('Request:\n${_pretty(s(r['request']))}\n\nAnswer:\n${_pretty(s(r['response']))}',
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                        ),
                      ],
                    ),
                  ),
              ]),
      );
}
