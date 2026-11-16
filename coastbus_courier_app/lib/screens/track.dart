import 'package:flutter/material.dart';
import '../api.dart';
import '../db.dart';
import '../docs.dart';
import '../fmt.dart';
import '../master.dart';
import '../printer.dart';
import '../scanner.dart';
import '../session.dart';
import '../ops.dart';
import '../ui.dart';
import 'collect.dart';

const scanLabels = {
  'book': 'Booked', 'load': 'Loaded', 'unload': 'Taken off before departure', 'depart': 'Departed', 'offload': 'Offloaded',
  'collect': 'Collected', 'recover': 'Recovered', 'cancel': 'Cancelled',
};

class TrackScreen extends StatefulWidget {
  const TrackScreen({super.key});
  @override
  State<TrackScreen> createState() => _TrackScreenState();
}

class _TrackScreenState extends State<TrackScreen> {
  List<Map<String, dynamic>> _list = [];
  bool _busy = false;

  Future<void> _find(String raw) async {
    setState(() => _busy = true);
    final r = await findWaybills(raw);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _list = r;
    });
    r.isEmpty ? Scanner.bad() : Scanner.good();
    if (r.length == 1) _open(r.first);
  }

  void _open(Map<String, dynamic> w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => WaybillPage(w: w)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Track parcel')),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        ScanBar(hint: 'Scan, or type waybill no. or phone', onCode: _find),
        if (_busy) const LinearProgressIndicator(),
        const SizedBox(height: 10),
        for (final w in _list)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            decoration: box(),
            child: ListTile(
              title: Text(s(w['name']), style: h(15)),
              subtitle: Text('${Master.i.hubCodeOf(n(w['origin_hub_id']))} → ${Master.i.hubCodeOf(n(w['destination_hub_id']))} · ${w['receiver_name']}'),
              trailing: StateChip(s(w['state'])),
              onTap: () => _open(w),
            ),
          ),
      ]),
    );
  }
}

class WaybillPage extends StatefulWidget {
  final Map<String, dynamic> w;
  const WaybillPage({super.key, required this.w});
  @override
  State<WaybillPage> createState() => _WaybillPageState();
}

class _WaybillPageState extends State<WaybillPage> {
  late Map<String, dynamic> w = widget.w;
  List<Map<String, dynamic>> _scans = [];
  String _err = '';

  @override
  void initState() {
    super.initState();
    _online();
  }

  Future<void> _online() async {
    try {
      final r = await Api.call('GET', '/waybill', query: {'q': s(w['name'])});
      if (r['waybill'] != null) {
        w = Map<String, dynamic>.from(r['waybill'] as Map);
        await Db.putWaybill(w);
      }
      _scans = ((r['scans'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on NetError catch (e) {
      _err = e.offline ? 'Offline: showing what this terminal knows.' : e.message;
    }
    if (mounted) setState(() {});
  }

  Future<void> _cancel() async {
    final reason = await ask(context, 'Cancel ${w['name']}?', label: 'Reason');
    if (reason == null || reason.trim().isEmpty || !mounted) return;
    final sup = await askSupervisor(context, 'Cancel ${w['name']} (${money(d(w['total']))}): $reason');
    if (sup == null) return;
    await Ops.cancel(w, reason.trim());
    if (!mounted) return;
    toast(context, 'Cancelled. Refund any money paid; Odoo makes a credit note.');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mine = n(w['origin_hub_id']) == Master.i.hubId;
    return Scaffold(
      appBar: AppBar(title: Text(s(w['name']))),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: box(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text('${Master.i.hubLabel(n(w['origin_hub_id']))} → ${Master.i.hubLabel(n(w['destination_hub_id']))}', style: h(17))), StateChip(s(w['state']))]),
            const SizedBox(height: 8),
            Text('Sender: ${w['sender_name']} ${localPhone(s(w['sender_phone']))}'),
            Text('Receiver: ${w['receiver_name']} ${localPhone(s(w['receiver_phone']))}'),
            Text('${w['description']} · ${w['pieces']} pc · ${kg(d(w['weight']))} · ${money(d(w['total']))} (${payLabels[w['payment_mode']] ?? w['payment_mode']})'),
            Text('Booked ${dtOdoo(s(w['booked_at']))}${s(w['booked_by']).isNotEmpty ? ' by ${w['booked_by']}' : ''}'),
            if (s(w['manifest_no']).isNotEmpty) Text('Manifest ${w['manifest_no']} · ${s(w['vehicle'])} ${s(w['custodian']).isNotEmpty ? '· custody ${w['custodian']}' : ''}'),
          ]),
        ),
        if (_err.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_err, style: const TextStyle(color: C.muted))),
        const Label('Custody history'),
        if (_scans.isEmpty) const Text('History shows when online.', style: TextStyle(color: C.muted)),
        for (final sc in _scans)
          ListTile(
            dense: true,
            leading: Icon(sc['result'] == 'ok' ? Icons.circle : Icons.error, size: 14, color: sc['result'] == 'ok' ? C.ink : C.red),
            title: Text('${scanLabels[sc['kind']] ?? sc['kind']}${n(sc['piece']) > 0 ? ' · piece ${sc['piece']}' : ''} · ${s(sc['hub'])}', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${dtOdoo(s(sc['at']))} · ${s(sc['by'])}${s(sc['manifest']).isNotEmpty ? ' · ${sc['manifest']}' : ''}${s(sc['note']).isNotEmpty ? '\n${sc['note']}' : ''}'),
          ),
        const Label('Print'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: () => Printer.print(Docs.receipt(w, copy: true), 'Receipt copy'), icon: const Icon(Icons.receipt), label: const Text('Receipt copy')),
          for (var p = 1; p <= (n(w['pieces']) < 1 ? 1 : n(w['pieces'])); p++)
            OutlinedButton.icon(onPressed: () => Printer.print(Docs.sticker(w, p), 'Label $p'), icon: const Icon(Icons.qr_code_2), label: Text('Label $p')),
        ]),
        if (mine && w['state'] == 'booked' && Session.i.canBook) ...[
          const SizedBox(height: 18),
          TextButton.icon(onPressed: _cancel, style: TextButton.styleFrom(foregroundColor: C.red), icon: const Icon(Icons.cancel_outlined), label: const Text('Cancel waybill (supervisor)')),
        ],
      ]),
    );
  }
}
