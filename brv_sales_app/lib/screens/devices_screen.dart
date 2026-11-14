import 'package:flutter/material.dart';
import '../fmt.dart';
import '../licence.dart';
import '../net.dart';
import '../sync.dart';
import '../ui.dart';

/// Manager app: the company's user devices (BRV Pos Sales) and the licence.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Map<String, dynamic>> _devices = [];
  String _error = '';
  bool _loading = true;
  int _me = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _use(Map<String, dynamic> r) async {
    if (r['licence'] is Map) await Licence.i.apply(Map<String, dynamic>.from(r['licence'] as Map));
    _devices = ((r['devices'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    _me = (r['me'] as num?)?.toInt() ?? _me;
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = ''; });
    try {
      await _use(await Net.call(Licence.i.server, 'GET', '/devices', headers: Licence.i.auth));
    } on NetError catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add() async {
    final lic = Licence.i;
    if (lic.devicesUsed >= lic.maxDevices) {
      toast(context, 'All ${lic.maxDevices} user devices are in use. Remove one, or ask BRV to allow more.');
      return;
    }
    final code = await ask(context, 'Add a user device', label: 'Code shown on the BRV Pos Sales device', hint: 'SXXX-XXXX-XXXX');
    if (code == null || code.trim().isEmpty || !mounted) return;
    final name = await ask(context, 'Name this device', label: 'e.g. Bar handheld, Counter 2', initial: '');
    try {
      await _use(await Net.call(lic.server, 'POST', '/devices',
          body: {'code': code.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase(), 'name': (name ?? '').trim()}, headers: lic.auth));
      if (mounted) toast(context, 'Device added. It opens by itself within a few seconds.');
    } on NetError catch (e) {
      if (mounted) toast(context, e.message);
    }
    if (mounted) setState(() {});
  }

  Future<void> _remove(Map<String, dynamic> d) async {
    if (!await confirm(context, 'Remove ${d['name']}?', 'It stops working for this company at its next sync. Its sales stay.', ok: 'Remove', danger: true)) return;
    try {
      await _use(await Net.call(Licence.i.server, 'DELETE', '/devices/${d['id']}', headers: Licence.i.auth));
    } on NetError catch (e) {
      if (mounted) toast(context, e.message);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final lic = Licence.i;
    return Scaffold(
      appBar: AppBar(title: const Text('Devices and licence'), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
      floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add_to_home_screen), label: const Text('Add device')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 90), children: [
          const LicenceCard(),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: Text('User devices', style: h(17))),
            Pill('${lic.devicesUsed} of ${lic.maxDevices} used', fg: lic.devicesUsed >= lic.maxDevices ? C.red : C.green,
                bg: lic.devicesUsed >= lic.maxDevices ? C.redLight : C.greenLight),
          ]),
          const SizedBox(height: 8),
          if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
          if (_error.isNotEmpty) Empty(Icons.cloud_off, '$_error\nThe list needs internet.'),
          for (final d in _devices)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: box(),
              child: ListTile(
                leading: Icon(d['role'] == 'manager' ? Icons.admin_panel_settings : Icons.point_of_sale,
                    color: d['active'] == true ? C.ink : C.muted),
                title: Text('${d['name']}${d['id'] == _me ? ' (this phone)' : ''}', style: TextStyle(fontWeight: FontWeight.w700, color: d['active'] == true ? C.text : C.muted)),
                subtitle: Text('${d['role'] == 'manager' ? 'Manager' : 'User device'} · no. ${d['device_no']}'
                    '${d['active'] == true ? '' : ' · removed'}\nLast sync: ${d['last_sync'] == null ? 'never' : dateText(DateTime.tryParse('${d['last_sync']}')?.toLocal().toIso8601String())}'),
                isThreeLine: true,
                trailing: d['role'] == 'sales' && d['active'] == true
                    ? IconButton(onPressed: () => _remove(d), icon: const Icon(Icons.remove_circle_outline, color: C.red))
                    : null,
              ),
            ),
          const SizedBox(height: 10),
          const Text('To add a device: install BRV Pos Sales on it, open it (with internet), then tap Add device and type the code it shows.', style: muted),
        ]),
      ),
    );
  }
}

/// Company, days left and sync state.
class LicenceCard extends StatelessWidget {
  const LicenceCard({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([Licence.i, Sync.i]),
        builder: (context, _) {
          final lic = Licence.i;
          final low = lic.daysLeft <= 7;
          return Container(
            padding: const EdgeInsets.all(18),
            decoration: box(color: C.ink, border: false),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(lic.company, style: h(19, color: Colors.white)),
              const SizedBox(height: 4),
              Text('Licence: ${lic.daysLeft} day${lic.daysLeft == 1 ? '' : 's'} left', style: h(24, color: low ? C.pink : C.gold)),
              if (lic.expiresAt != null)
                Text('Until ${dateText(lic.expiresAt!.toIso8601String(), time: false)}', style: const TextStyle(color: Color(0xFFCBD5E1))),
              const SizedBox(height: 8),
              Row(children: [
                Icon(Sync.i.error.isEmpty ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, color: const Color(0xFFCBD5E1), size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(Sync.i.statusText, style: const TextStyle(color: Color(0xFFCBD5E1)))),
                TextButton(onPressed: Sync.i.busy ? null : () => Sync.i.run(), child: const Text('Sync now', style: TextStyle(color: Colors.white))),
              ]),
              Text('Device ${lic.shownCode} · no. ${lic.deviceNo}', style: const TextStyle(color: Color(0xFF8C9AB3), fontSize: 12)),
            ]),
          );
        },
      );
}

/// Small cloud chip for the top bar: tap to sync.
class SyncChip extends StatelessWidget {
  const SyncChip({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Sync.i,
        builder: (context, _) {
          final sy = Sync.i;
          final icon = sy.busy ? Icons.sync : (sy.error.isNotEmpty ? Icons.cloud_off_outlined : (sy.pending > 0 ? Icons.cloud_upload_outlined : Icons.cloud_done_outlined));
          final color = sy.error.isNotEmpty ? C.amber : (sy.pending > 0 ? C.ink2 : C.green);
          return IconButton(
            tooltip: sy.statusText,
            onPressed: () {
              toast(context, sy.statusText);
              sy.run();
            },
            icon: Badge(isLabelVisible: sy.pending > 0, label: Text('${sy.pending}'), child: Icon(icon, color: color)),
          );
        },
      );
}
