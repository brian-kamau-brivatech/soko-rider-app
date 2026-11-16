import 'package:flutter/material.dart';
import '../api.dart';
import '../db.dart';
import '../fmt.dart';
import '../master.dart';
import '../printer.dart';
import '../session.dart';
import '../sync.dart';
import '../ui.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic> _info = {};
  String _choice = 'auto';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _choice = await Printer.choice();
    _info = await Printer.info();
    if (mounted) setState(() {});
  }

  void _pick(String? v) {
    if (v == null) return;
    setState(() => _choice = v);
    Printer.setChoice(v);
  }

  Future<void> _test() async {
    final ok = await Printer.print([
      PLine.center(s(Master.i.company['name']), size: 24, bold: true),
      PLine.center('Printer test · ${Master.i.hubName}'),
      PLine.center(dt(DateTime.now())),
      const PLine.big('NAIROBI'),
      const PLine.qr('CB-TEST-00-00001/1', size: 170),
      const PLine.barcode('CB-TEST-00-00001/1'),
      const PLine.center('CB-TEST-00-00001/1', bold: true),
    ], 'Test');
    if (mounted) toast(context, ok ? 'Printed (${Printer.lastMethod}).' : 'Printing failed (${Printer.lastMethod}).', bad: !ok);
  }

  Future<void> _reactivate() async {
    final sup = await askSupervisor(context, 'Re-activate this terminal (needs a new key from Odoo)');
    if (sup == null || !mounted) return;
    final pending = await Db.count("SELECT COUNT(*) FROM outbox WHERE status = 'pending'");
    if (pending > 0 && !await confirm(context, 'Records not sent', '$pending records have not reached Odoo yet. They are kept and sent after activation.', ok: 'Continue')) {
      return;
    }
    Session.i.lock();
    await Sync.i.forget();
  }

  @override
  Widget build(BuildContext context) {
    final printers = ((_info['printers'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final m = Master.i;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        const Label('Printer'),
        Container(
          decoration: box(),
          child: Column(children: [
            RadioListTile<String>(value: 'auto', groupValue: _choice, onChanged: _pick, title: const Text('Automatic (built-in printer first)')),
            for (final p in printers)
              RadioListTile<String>(value: s(p['id']), groupValue: _choice, onChanged: _pick, title: Text(s(p['label']))),
            RadioListTile<String>(value: 'dialog', groupValue: _choice, onChanged: _pick, title: const Text('Ask each time (Android printing)')),
          ]),
        ),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const [ButtonSegment(value: 58, label: Text('58 mm paper')), ButtonSegment(value: 80, label: Text('80 mm paper'))],
          selected: {Printer.paperMm},
          onSelectionChanged: (v) {
            Printer.setPaper(v.first);
            setState(() {});
          },
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton.icon(onPressed: _test, icon: const Icon(Icons.print), label: const Text('Test print'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.bluetooth_searching), label: const Text('Find printers'))),
        ]),
        if (_info['bluetoothAllowed'] == false) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Allow "Nearby devices" for this app to use a Bluetooth printer.', style: TextStyle(color: C.muted))),
        const Label('Terminal'),
        Container(
          decoration: box(),
          child: Column(children: [
            ListTile(dense: true, title: const Text('Branch'), trailing: Text('${m.hubName} (${m.hubCode})')),
            ListTile(dense: true, title: const Text('Terminal no.'), trailing: Text('${m.deviceNo} · ${s(m.device['name'])}')),
            ListTile(dense: true, title: const Text('Model'), trailing: Text(s(_info['model']))),
            ListTile(dense: true, title: const Text('Signed in'), trailing: Text(Session.i.name)),
          ]),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () async {
            await Db.setKv('since', '');
            final ok = await Sync.i.run(full: true);
            if (context.mounted) toast(context, ok ? 'Everything downloaded again.' : Sync.i.error, bad: !ok);
          },
          icon: const Icon(Icons.cloud_sync_outlined),
          label: const Text('Download everything again'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(onPressed: _reactivate, style: TextButton.styleFrom(foregroundColor: C.red), icon: const Icon(Icons.restart_alt), label: const Text('Re-activate terminal (supervisor)')),
      ]),
    );
  }
}
