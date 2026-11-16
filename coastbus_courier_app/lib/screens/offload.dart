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
import '../sync.dart';
import '../ui.dart';
import 'load.dart';

/// Arrival: pick the vehicle (or scan its manifest slip), scan every piece off, tally loaded vs offloaded.
class OffloadScreen extends StatefulWidget {
  const OffloadScreen({super.key});
  @override
  State<OffloadScreen> createState() => _OffloadScreenState();
}

class _OffloadScreenState extends State<OffloadScreen> {
  List<Map<String, dynamic>> _inbound = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    Sync.i.run();
  }

  Future<void> _load() async {
    final hub = Master.i.hubId;
    final all = await Db.manifests("state = 'in_transit'");
    _inbound = all.where((m) => m['received_at_$hub'] == null && Ops.expected(m, hub).isNotEmpty).toList();
    if (mounted) setState(() {});
  }

  Future<void> _byNumber(String raw) async {
    final c = await parseCode(raw);
    final no = c.kind == 'manifest' ? c.name : raw.trim().toUpperCase();
    var m = await Db.manifest(no);
    if (m == null) {
      setState(() => _busy = true);
      try {
        final r = await Api.call('GET', '/manifest', query: {'q': no});
        m = Map<String, dynamic>.from(r['manifest'] as Map);
        await Db.putManifest(m);
        for (final w in (r['waybills'] as List? ?? const [])) {
          await Db.putWaybill(Map<String, dynamic>.from(w as Map));
        }
      } on NetError catch (e) {
        if (mounted) toast(context, e.offline ? 'Manifest $no not on this terminal and no network to fetch it.' : e.message, bad: true);
        Scanner.bad();
        return;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    Scanner.good();
    _openPage(m);
  }

  Future<void> _openPage(Map<String, dynamic> m) async {
    if (m['state'] == 'loading') {
      toast(context, '${m['name']} has not departed yet (still loading at ${Master.i.hubLabel(n(m['origin_hub_id']))}).', bad: true);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OffloadPage(m: m)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Sync.i,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Offload vehicle')),
        body: RefreshIndicator(
          onRefresh: () async {
            await Sync.i.run();
            await _load();
          },
          child: ListView(padding: const EdgeInsets.all(14), children: [
            ScanBar(hint: 'Scan the manifest slip QR or type MNF-…', onCode: _byNumber),
            if (_busy) const LinearProgressIndicator(),
            const Label('Vehicles expected here'),
            if (_inbound.isEmpty) const Empty(Icons.local_shipping_outlined, 'No vehicle on the way to this branch. Pull down to refresh, or scan the driver\'s manifest slip.'),
            for (final m in _inbound)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: box(),
                child: ListTile(
                  leading: const Icon(Icons.local_shipping, color: C.ink, size: 32),
                  title: Text('${m['vehicle']} from ${Master.i.hubLabel(n(m['origin_hub_id']))}', style: h(15)),
                  subtitle: Text('${m['name']} · ${m['driver']}\nDeparted ${dtOdoo(s(m['departure_time']))} · '
                      '${Ops.expected(m, Master.i.hubId).fold<int>(0, (a, l) => a + piecesOf(l['loaded']).length)} pieces for here'),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openPage(m),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class OffloadPage extends StatefulWidget {
  final Map<String, dynamic> m;
  const OffloadPage({super.key, required this.m});
  @override
  State<OffloadPage> createState() => _OffloadPageState();
}

class _OffloadPageState extends State<OffloadPage> {
  late Map<String, dynamic> m = widget.m;
  String _flash = '';
  bool _flashBad = false;
  bool _busy = false;
  int get hub => Master.i.hubId;

  List<Map<String, dynamic>> get _exp => Ops.expected(m, hub);
  int get _expPieces => _exp.fold(0, (a, l) => a + piecesOf(l['loaded']).length);
  int get _gotPieces => _exp.fold(0, (a, l) => a + piecesOf(l['received']).intersection(piecesOf(l['loaded'])).length);
  List<Map<String, dynamic>> get _extras => Ops.lines(m).where((l) => l['extra'] == true && n(l['received_hub_id']) == hub).toList();

  void _say(String msg, {bool bad = false}) {
    setState(() {
      _flash = msg;
      _flashBad = bad;
    });
    bad ? Scanner.bad() : Scanner.good();
  }

  Future<void> _code(String raw) async {
    if (_busy) return;
    _busy = true;
    try {
      final c = await parseCode(raw);
      if (!c.isWaybill) {
        _say('Not a parcel label: $raw', bad: true);
        return;
      }
      final l = Ops.line(m, c.name);
      final w = await Db.waybill(c.name);
      if (l == null || (l['extra'] == true && n(l['received_hub_id']) != hub)) {
        Scanner.bad();
        final keep = await confirm(context, 'Not on this manifest',
            '${c.name} was never scanned onto ${m['vehicle']} at loading. Take it off here anyway? It is recorded as an unexpected parcel for investigation.',
            ok: 'Take off here');
        if (!keep) {
          _say('${c.name} not on this manifest', bad: true);
          return;
        }
        await Ops.offloadPiece(m, w, c.name, c.piece, extra: true);
        m = await Db.manifest(s(m['name'])) ?? m;
        _say('${c.name} recorded as unexpected', bad: true);
        return;
      }
      if (l['extra'] != true && !_exp.any((x) => x['name'] == c.name)) {
        _say('${c.name} is for ${Master.i.hubLabel(n(l['destination_hub_id']))}. Leave it on the vehicle.', bad: true);
        return;
      }
      if (piecesOf(l['received']).contains(c.piece)) {
        _say('${c.name} piece ${c.piece} already scanned', bad: true);
        return;
      }
      if (c.piece > (n(l['pieces']) < 1 ? 1 : n(l['pieces']))) {
        _say('${c.name} has only ${l['pieces']} piece(s)', bad: true);
        return;
      }
      await Ops.offloadPiece(m, w, c.name, c.piece);
      m = await Db.manifest(s(m['name'])) ?? m;
      _say('✓ ${c.name}${n(l['pieces']) > 1 ? ' piece ${c.piece}/${l['pieces']}' : ''}   [$_gotPieces / $_expPieces]');
    } finally {
      _busy = false;
    }
  }

  Future<void> _finish() async {
    final short = Ops.shortages(m, hub);
    if (short.isEmpty) {
      if (!await confirm(context, 'All pieces received', '$_gotPieces of $_expPieces pieces offloaded. Close offloading and print the driver clearance?', ok: 'Close & print')) {
        return;
      }
      final got = _gotPieces;
      await Ops.receiveComplete(m);
      await Printer.print(Docs.clearance(m, got), 'Clearance ${m['name']}');
      if (mounted) {
        toast(context, 'Offloading closed. Receivers get their collection SMS.');
        Navigator.of(context).pop();
      }
      return;
    }
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ShortageScreen(m: m, short: short, expected: _expPieces, received: _gotPieces)));
    if (done == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final exp = _exp;
    final full = _expPieces > 0 && _gotPieces >= _expPieces;
    return Scaffold(
      appBar: AppBar(title: Text('${m['vehicle']} · ${m['name']}')),
      body: Column(children: [
        Container(
          color: full ? C.green : C.ink,
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
          child: Row(children: [
            Expanded(child: HeadStat('$_gotPieces / $_expPieces', 'pieces offloaded')),
            Expanded(child: HeadStat('${exp.where((l) => piecesOf(l['loaded']).difference(piecesOf(l['received'])).isEmpty).length} / ${exp.length}', 'waybills complete')),
            if (_extras.isNotEmpty) Expanded(child: HeadStat('${_extras.length}', 'unexpected')),
          ]),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 6), child: ScanBar(onCode: _code)),
        if (_flash.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.all(12),
            decoration: box(color: _flashBad ? C.redLight : C.greenLight, border: false),
            child: Text(_flash, style: TextStyle(fontWeight: FontWeight.w800, color: _flashBad ? C.red : C.green, fontSize: 16)),
          ),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(12), children: [
            for (final l in exp)
              Builder(builder: (context) {
                final loaded = piecesOf(l['loaded']), got = piecesOf(l['received']);
                final missing = loaded.difference(got);
                final done = missing.isEmpty;
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: box(color: done ? C.greenLight : Colors.white),
                  child: ListTile(
                    dense: true,
                    leading: Icon(done ? Icons.check_circle : (got.isEmpty ? Icons.radio_button_unchecked : Icons.timelapse), color: done ? C.green : (got.isEmpty ? C.muted : C.amber)),
                    title: Text(s(l['name']), style: h(15)),
                    subtitle: Text('${got.intersection(loaded).length}/${loaded.length} pc${missing.isNotEmpty && got.isNotEmpty ? ' · missing ${piecesText(missing)}' : ''} · ${s(l['description'])}'),
                  ),
                );
              }),
            if (_extras.isNotEmpty) const Label('Unexpected (not loaded on this manifest)'),
            for (final l in _extras)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                decoration: box(color: C.amberLight),
                child: ListTile(dense: true, leading: const Icon(Icons.help_outline, color: C.amber), title: Text(s(l['name']), style: h(15)), subtitle: Text('pieces ${l['received']}')),
              ),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: full ? C.green : C.ink),
                onPressed: _finish,
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(full ? 'All received · close' : 'Finish offloading'),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Red alert: pieces loaded at origin but not offloaded. Driver acknowledges with PIN, supervisor approves, docket printed.
class ShortageScreen extends StatefulWidget {
  final Map<String, dynamic> m;
  final List<(Map<String, dynamic>, Set<int>)> short;
  final int expected, received;
  const ShortageScreen({super.key, required this.m, required this.short, required this.expected, required this.received});
  @override
  State<ShortageScreen> createState() => _ShortageScreenState();
}

class _ShortageScreenState extends State<ShortageScreen> {
  final _note = TextEditingController();
  bool _driverAck = false;
  Map<String, dynamic>? _sup;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Scanner.bad();
  }

  Future<void> _driver() async {
    final drv = Master.i.staffById(n(widget.m['driver_id']));
    if (drv == null || s(drv['pin_hash']).isEmpty) {
      final ok = await confirm(context, 'Driver PIN not available', 'Record the shortage without the driver\'s PIN? The driver signs the printed docket instead.', ok: 'Continue');
      if (ok) setState(() => _driverAck = false);
      return;
    }
    if (await askPinOf(context, drv, 'I confirm the missing pieces listed were in my custody and were not offloaded.')) {
      setState(() => _driverAck = true);
    }
  }

  Future<void> _record() async {
    final sup = _sup ?? await askSupervisor(context, 'Approve the shortage record for ${widget.m['name']}');
    if (sup == null || !mounted) return;
    setState(() {
      _sup = sup;
      _busy = true;
    });
    final wbs = <String, Map<String, dynamic>>{};
    for (final x in widget.short) {
      final w = await Db.waybill(s(x.$1['name']));
      if (w != null) wbs[s(x.$1['name'])] = w;
    }
    await Ops.receiveComplete(widget.m, driverAck: _driverAck, supervisorId: n(sup['id']), note: _note.text.trim());
    await Printer.print(Docs.docket(widget.m, widget.short, wbs, expected: widget.expected, received: widget.received, supervisor: s(sup['name'])), 'Shortage ${widget.m['name']}');
    if (!mounted) return;
    toast(context, 'Shortage recorded. Investigation opened in Odoo.');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final missingPieces = widget.short.fold<int>(0, (a, x) => a + x.$2.length);
    return Scaffold(
      backgroundColor: C.redLight,
      appBar: AppBar(backgroundColor: C.red, title: const Text('SHORTAGE')),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: box(color: C.red, border: false),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 40),
            Text('$missingPieces piece${missingPieces == 1 ? '' : 's'} missing', style: h(26, color: Colors.white)),
            Text('Expected ${widget.expected} · received ${widget.received}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Loaded onto ${widget.m['vehicle']} (driver ${widget.m['driver']}) but not offloaded. Check the vehicle again before recording.',
                style: const TextStyle(color: Colors.white)),
          ]),
        ),
        const Label('Missing'),
        for (final x in widget.short)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            decoration: box(),
            child: ListTile(
              leading: const Icon(Icons.inventory_2_outlined, color: C.red),
              title: Text(s(x.$1['name']), style: h(15)),
              subtitle: Text('Piece${x.$2.length == 1 ? '' : 's'} ${piecesText(x.$2)} of ${x.$1['pieces']} · ${s(x.$1['description'])}'),
            ),
          ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
          onPressed: () => Navigator.of(context).pop(false),
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Go back and scan again'),
        ),
        const Label('Record the shortage'),
        TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (vehicle checked, driver statement…)'), maxLines: 2),
        const SizedBox(height: 10),
        ListTile(
          tileColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          leading: Icon(_driverAck ? Icons.verified : Icons.badge_outlined, color: _driverAck ? C.green : C.muted),
          title: Text(_driverAck ? 'Driver acknowledged (PIN)' : 'Driver acknowledges with PIN'),
          subtitle: Text(s(widget.m['driver'])),
          onTap: _driverAck ? null : _driver,
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: C.red),
          onPressed: _busy ? null : _record,
          icon: const Icon(Icons.print),
          label: const Text('Supervisor approves · print docket'),
        ),
      ]),
    );
  }
}
