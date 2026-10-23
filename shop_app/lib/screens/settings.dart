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
  String _printer = 'auto';
  String _printerLabel = 'Automatic';
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
    _loadPrinter();
  }

  Future<void> _loadPrinter() async {
    final id = await Receipt.printerChoice();
    var label = id == 'auto' ? 'Automatic' : id == 'dialog' ? 'Android print screen (preview)' : id;
    if (id != 'auto' && id != 'dialog') {
      final info = await Receipt.printerInfo();
      for (final p in (info['printers'] as List?) ?? const []) {
        if (p is Map && p['id'] == id) label = '${p['label']}';
      }
    }
    if (mounted) {
      setState(() {
        _printer = id;
        _printerLabel = label;
      });
    }
  }

  /// Pick the printer: every printer this handheld can print to without a
  /// preview, Automatic, or Android's print screen.
  Future<void> _pickPrinter() async {
    final info = await Receipt.printerInfo();
    if (!mounted) return;
    final printers = ((info['printers'] as List?) ?? const []).whereType<Map>().toList();
    final options = <(String, String, String)>[
      ('auto', 'Automatic', printers.isEmpty ? 'No direct printer found: uses the print screen' : 'First printer that prints without a preview'),
      for (final p in printers) ('${p['id']}', '${p['label']}', 'Prints straight away · ${p['package']}'),
      ('dialog', 'Android print screen', 'Shows a preview first, then you tap print'),
    ];
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Printer', style: h(18))),
          for (final o in options)
            ListTile(
              leading: Icon(_printer == o.$1 ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: _printer == o.$1 ? C.green : C.muted),
              title: Text(o.$2, style: h(15, w: FontWeight.w700)),
              subtitle: Text(o.$3),
              onTap: () => Navigator.pop(ctx, o.$1),
            ),
          const SizedBox(height: 10),
        ]),
      ),
    );
    if (picked == null) return;
    await Receipt.setPrinterChoice(picked);
    await _loadPrinter();
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
            ? 'Used the Android print screen. Pick your printer in Settings > Printer.'
            : 'Printed directly, no preview.');
  }

  Future<void> _printerCheck() async {
    final i = await Receipt.printerInfo();
    if (!mounted) return;
    final printers = ((i['printers'] as List?) ?? const []).whereType<Map>().toList();
    final lines = <String>[
      'Device: ${i['model'] ?? '?'} · Android ${i['android'] ?? '?'}',
      'Direct printing: ${printers.isEmpty ? 'No' : 'Yes'}',
      ...printers.map((p) => '• ${p['label']}'),
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
              ListTile(
                leading: const Icon(Icons.print_outlined, color: C.navy),
                title: const Text('Printer'),
                subtitle: Text(_printerLabel),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _pickPrinter,
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
