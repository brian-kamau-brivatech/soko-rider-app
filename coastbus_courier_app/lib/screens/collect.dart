import 'package:flutter/material.dart';
import '../api.dart';
import '../codes.dart';
import '../db.dart';
import '../docs.dart';
import '../fmt.dart';
import '../master.dart';
import '../ops.dart';
import '../printer.dart';
import '../scanner.dart';
import '../session.dart';
import '../ui.dart';

/// Find a parcel at this branch: scan the sender's receipt QR / label, type the waybill number or the receiver's phone.
Future<List<Map<String, dynamic>>> findWaybills(String raw) async {
  final c = await parseCode(raw);
  if (c.isWaybill) {
    final w = await Db.waybill(c.name);
    if (w != null) return [w];
  }
  final p = normPhone(raw);
  if (p.length >= 10) {
    final l = await Db.waybills('receiver_phone = ? OR sender_phone = ?', [p, p], 'booked_at DESC', 30);
    if (l.isNotEmpty) return l;
  }
  // not on this terminal: ask Odoo
  try {
    final r = await Api.call('GET', '/waybill', query: {'q': c.kind == 'token' ? raw : (c.isWaybill ? c.name : raw.trim())});
    if (r['waybill'] != null) {
      final w = Map<String, dynamic>.from(r['waybill'] as Map);
      await Db.putWaybill(w);
      return [w];
    }
    return ((r['many'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  } on NetError {
    return [];
  }
}

class CollectScreen extends StatefulWidget {
  const CollectScreen({super.key});
  @override
  State<CollectScreen> createState() => _CollectScreenState();
}

class _CollectScreenState extends State<CollectScreen> {
  List<Map<String, dynamic>> _list = [];
  String _q = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _waiting();
  }

  Future<void> _waiting() async {
    _list = await Db.waybills("state = 'arrived' AND dest = ?", [Master.i.hubId], 'booked_at DESC', 300);
    _q = '';
    if (mounted) setState(() {});
  }

  Future<void> _find(String raw) async {
    setState(() => _busy = true);
    final r = await findWaybills(raw);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _q = raw;
      _list = r;
    });
    if (r.isEmpty) {
      Scanner.bad();
      toast(context, 'Nothing found for "$raw".', bad: true);
    } else {
      Scanner.good();
      if (r.length == 1) _open(r.first);
    }
  }

  Future<void> _open(Map<String, dynamic> w) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CollectPage(w: w)));
    _waiting();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Collect parcel')),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        ScanBar(hint: 'Scan receipt / label, or type waybill no. or phone', onCode: _find),
        if (_busy) const LinearProgressIndicator(),
        Label(_q.isEmpty ? 'Waiting for collection here (${_list.length})' : 'Results for "$_q"'),
        if (_list.isEmpty) const Empty(Icons.inventory_2_outlined, 'No parcels waiting here.'),
        for (final w in _list)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            decoration: box(),
            child: ListTile(
              title: Text('${w['name']} · ${w['receiver_name']}', style: h(15)),
              subtitle: Text('${localPhone(s(w['receiver_phone']))} · from ${Master.i.hubLabel(n(w['origin_hub_id']))} · ${w['pieces']} pc'),
              trailing: StateChip(s(w['state'])),
              onTap: () => _open(w),
            ),
          ),
      ]),
    );
  }
}

class CollectPage extends StatefulWidget {
  final Map<String, dynamic> w;
  const CollectPage({super.key, required this.w});
  @override
  State<CollectPage> createState() => _CollectPageState();
}

class _CollectPageState extends State<CollectPage> {
  late final _name = TextEditingController(text: s(widget.w['receiver_name']));
  final _id = TextEditingController();
  final _otp = TextEditingController();
  bool _busy = false;

  Map<String, dynamic> get w => widget.w;

  Future<void> _release({required bool override}) async {
    if (_name.text.trim().isEmpty) {
      toast(context, 'Enter the name of the person collecting.', bad: true);
      return;
    }
    var method = 'otp';
    if (!override) {
      final hash = s(w['otp_hash']);
      if (hash.isEmpty) {
        toast(context, 'The collection code is not on this terminal yet. Sync, or release with ID + supervisor.', bad: true);
        return;
      }
      if (otpHash(_otp.text.trim(), s(w['name'])) != hash) {
        Scanner.bad();
        toast(context, 'Wrong collection code.', bad: true);
        return;
      }
    } else {
      if (_id.text.trim().length < 5) {
        toast(context, 'Enter the ID number of the person collecting.', bad: true);
        return;
      }
      if (Master.i.flag('collect_needs_otp')) {
        final sup = await askSupervisor(context, 'Release ${w['name']} without the SMS code (ID ${_id.text.trim()})');
        if (sup == null) return;
      }
      method = 'override';
    }
    setState(() => _busy = true);
    await Ops.collect(w, name: _name.text.trim(), idNo: _id.text.trim(), method: method);
    await Printer.print(Docs.collection(w, name: _name.text.trim(), idNo: _id.text.trim(), method: method), 'Collection ${w['name']}');
    if (!mounted) return;
    Scanner.good();
    toast(context, '${w['name']} released to ${_name.text.trim()}.');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = s(w['state']);
    final here = n(w['destination_hub_id']) == Master.i.hubId;
    final ready = state == 'arrived' && here;
    final needOtp = Master.i.flag('collect_needs_otp');
    return Scaffold(
      appBar: AppBar(title: Text(s(w['name']))),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: box(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(s(w['name']), style: h(20))), StateChip(state)]),
            const SizedBox(height: 8),
            _kv('From', '${Master.i.hubLabel(n(w['origin_hub_id']))} · ${s(w['sender_name'])}'),
            _kv('To', '${Master.i.hubLabel(n(w['destination_hub_id']))} · ${s(w['receiver_name'])} ${localPhone(s(w['receiver_phone']))}'),
            _kv('Parcel', '${w['description']} · ${w['pieces']} pc · ${kg(d(w['weight']))}'),
            if (w['payment_mode'] == 'account') _kv('Payment', 'Account customer'),
            if (s(w['arrived_at']).isNotEmpty) _kv('Arrived', dtOdoo(s(w['arrived_at']))),
            if (state == 'collected') _kv('Collected', '${dtOdoo(s(w['collected_at']))} by ${s(w['collected_by_name'])}'),
          ]),
        ),
        const SizedBox(height: 12),
        if (!ready)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: box(color: C.amberLight, border: false),
            child: Text(
              !here
                  ? 'This parcel is for ${Master.i.hubLabel(n(w['destination_hub_id']))}, not this branch.'
                  : state == 'collected'
                      ? 'Already collected.'
                      : state == 'lost'
                          ? 'Recorded missing. A supervisor must resolve the investigation in Odoo first.'
                          : 'Not ready: ${stateLabels[state] ?? state}. It can be released after it is offloaded here.',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          )
        else ...[
          const Label('Person collecting'),
          TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 8),
          TextField(controller: _id, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'ID number')),
          const Label('Collection code (SMS to the receiver)'),
          TextField(controller: _otp, keyboardType: TextInputType.number, maxLength: 6, decoration: const InputDecoration(labelText: '6-digit code')),
          FilledButton.icon(onPressed: _busy ? null : () => _release(override: false), icon: const Icon(Icons.lock_open), label: const Text('Check code & release')),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _release(override: true),
            icon: const Icon(Icons.verified_user_outlined),
            label: Text(needOtp ? 'No code: ID + supervisor' : 'Release with ID'),
          ),
        ],
      ]),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 80, child: Text(k, style: const TextStyle(color: C.muted))),
          Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}
