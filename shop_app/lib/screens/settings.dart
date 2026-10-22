import 'package:flutter/material.dart';
import '../alerts.dart';
import '../api.dart';
import '../receipt.dart';
import '../store.dart';
import '../ui.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  Map<String, bool> _perm = const {};
  bool _direct = true;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
    Receipt.directEnabled().then((v) {
      if (mounted) setState(() => _direct = v);
    });
  }

  Future<void> _testPrint() async {
    setState(() => _testing = true);
    final now = DateTime.now().toString().substring(0, 16);
    final sale = Sale.fromJson({
      'id': 0, 'name': 'TEST PRINT', 'ref': 'Printer test', 'date': now, 'amount': 0, 'state': 'paid',
      'cashier': Store.i.cashierName.isEmpty ? 'Soko Shop' : Store.i.cashierName,
      'payments': [], 'lines': [{'name': 'Printer test', 'qty': 1, 'price': 0, 'total': 0}],
    });
    final ok = await Receipt.print(sale);
    if (!mounted) return;
    setState(() => _testing = false);
    toast(context, !ok
        ? 'Could not print.'
        : Receipt.lastMethod == 'dialog'
            ? 'Printed with the Android print screen (no direct printer service found).'
            : 'Printed directly (${Receipt.lastMethod}).');
  }

  Future<void> _printerCheck() async {
    final i = await Receipt.printerInfo();
    if (!mounted) return;
    final direct = i['sunmi'] == true ? 'Yes (Sunmi service)' : i['nyx'] == true ? 'Yes (Nyx service)' : 'No';
    final lines = <String>[
      'Device: ${i['model'] ?? '?'} · Android ${i['android'] ?? '?'}',
      'Direct printing: $direct',
      if (i['ipos'] == true) 'iPos printer service found (send this screen to Claude to add it).',
      '',
      'Printer apps:',
      ...((i['packages'] as List?) ?? const []).map((e) => '• $e'),
      '',
      'Android print services:',
      ...((i['printServices'] as List?) ?? const []).map((e) => '• $e'),
      if (i['error'] != null) 'Error: ${i['error']}',
    ];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Printer check'),
        content: SingleChildScrollView(child: SelectableText(lines.join('\n'))),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final p = await Alerts.status();
    if (mounted) setState(() => _perm = p);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: Store.i,
        builder: (context, _) {
          final s = Store.i;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
            Text('Settings', style: h(22)),
            const SizedBox(height: 14),
            _section('Ringing', [
              _picker('Ring sound', Alerts.sounds, s.sound, (v) => s.setSetting('sound', v)),
              _picker('Vibration', Alerts.vibrations, s.vibration, (v) => s.setSetting('vibration', v)),
              SwitchListTile(
                activeColor: C.green,
                title: const Text('Keep ringing until opened'),
                subtitle: const Text('Up to 5 minutes. Off = 30 seconds.'),
                value: s.keepRinging,
                onChanged: (v) => s.setSetting('keepRinging', v),
              ),
              ListTile(
                leading: const Icon(Icons.play_circle_outline_rounded, color: C.green),
                title: const Text('Test the alert'),
                onTap: () => Alerts.preview(s.sound, s.vibration),
              ),
            ]),
            _section('Alert me when', [
              _toggle('New paid order', 'RINGS', s.ringNewOrder, (v) => s.setSetting('ringNewOrder', v)),
              _toggle('No rider found', 'RINGS', s.ringNoRider, (v) => s.setSetting('ringNoRider', v)),
              _toggle('Rider arrived at the shop', 'CHIME', s.chimeRiderAtShop, (v) => s.setSetting('chimeRiderAtShop', v)),
            ]),
            _section('This device', [
              SwitchListTile(
                activeColor: C.green,
                title: const Text('Keep screen on'),
                subtitle: const Text('Best for the counter device on its charger.'),
                value: s.screenOn,
                onChanged: (v) => s.setSetting('screenOn', v),
              ),
              _perm1('Notifications allowed', _perm['notifications'], Alerts.openAppSettings),
              _perm1('Show over lock screen', _perm['fullScreen'], Alerts.openFullScreenSettings),
              _perm1('Keep running when locked', _perm['battery'], Alerts.openBatterySettings,
                  hint: 'Choose Soko Shop → Unrestricted / Don\'t optimise'),
            ]),
            _section('Printing', [
              SwitchListTile(
                activeColor: C.green,
                title: const Text('Print straight away'),
                subtitle: const Text('No print preview when the printer service allows it.'),
                value: _direct,
                onChanged: (v) async {
                  await Receipt.setDirect(v);
                  setState(() => _direct = v);
                },
              ),
              ListTile(
                leading: const Icon(Icons.print_rounded, color: C.green),
                title: const Text('Test print'),
                subtitle: const Text('Prints a short receipt with the logo.'),
                trailing: _testing
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: C.green))
                    : null,
                onTap: _testing ? null : _testPrint,
              ),
              ListTile(
                leading: const Icon(Icons.manage_search_rounded, color: C.navy),
                title: const Text('Printer check'),
                subtitle: const Text('Which printer service this handheld has.'),
                onTap: _printerCheck,
              ),
            ]),
            _section('Shop', [
              ListTile(
                leading: const Icon(Icons.storefront_rounded, color: C.navy),
                title: Text(s.shopName),
                subtitle: const Text('Signed in with the shop PIN'),
              ),
              ListTile(
                leading: const Icon(Icons.logout_rounded, color: C.red),
                title: const Text('Sign out this device', style: TextStyle(color: C.red, fontWeight: FontWeight.w700)),
                subtitle: const Text('It will stop receiving orders.'),
                onTap: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Sign out?'),
                      content: const Text('This device will stop ringing for new orders.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
                      ],
                    ),
                  );
                  if (ok == true) await s.signOut();
                },
              ),
            ]),
          ]);
        },
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(left: 4, bottom: 6), child: Text(title.toUpperCase(), style: h(12, color: C.muted).copyWith(letterSpacing: 0.8))),
          Container(decoration: card(), child: Column(children: children)),
        ]),
      );

  Widget _picker(String label, Map<String, String> options, String value, ValueChanged<String> onChanged) => ListTile(
        title: Text(label),
        trailing: DropdownButton<String>(
          value: options.containsKey(value) ? value : options.keys.first,
          underline: const SizedBox.shrink(),
          items: [for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      );

  Widget _toggle(String label, String kind, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        activeColor: C.green,
        title: Text(label),
        subtitle: Text(value ? kind : 'SILENT', style: TextStyle(fontWeight: FontWeight.w700, color: value ? C.green : C.muted, fontSize: 12)),
        value: value,
        onChanged: onChanged,
      );

  Widget _perm1(String label, bool? ok, Future<void> Function() fix, {String? hint}) => ListTile(
        leading: Icon(ok == true ? Icons.check_circle_rounded : Icons.error_outline_rounded, color: ok == true ? C.green : C.amber),
        title: Text(label),
        subtitle: ok == true ? null : Text(hint ?? 'Tap Allow to fix'),
        trailing: ok == true
            ? null
            : TextButton(
                onPressed: () async {
                  await fix();
                },
                child: const Text('Allow'),
              ),
      );
}
