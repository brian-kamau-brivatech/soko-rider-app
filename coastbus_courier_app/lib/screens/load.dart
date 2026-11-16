import 'package:flutter/material.dart';
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

/// Loading dock: open a trip (final stop, vehicle, driver), scan every piece onto it, depart.
class LoadScreen extends StatefulWidget {
  const LoadScreen({super.key});
  @override
  State<LoadScreen> createState() => _LoadScreenState();
}

class _LoadScreenState extends State<LoadScreen> {
  List<Map<String, dynamic>> _open = [];
  int _waiting = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _open = await Db.manifests("state = 'loading' AND origin = ?", [Master.i.hubId]);
    _waiting = await Db.count("SELECT COUNT(*) FROM waybills WHERE state IN ('booked', 'at_hub') AND cur = ?", [Master.i.hubId]);
    if (mounted) setState(() {});
  }

  Future<void> _new() async {
    final m = Master.i;
    final hubs = m.hubs.where((h) => n(h['id']) != m.hubId).toList();
    final drivers = m.staff.where((st) => st['role'] == 'loader' || st['role'] == 'supervisor').toList();
    if (m.vehicles.isEmpty || drivers.isEmpty || hubs.isEmpty) {
      toast(context, 'Add vehicles, drivers (staff role Loader/Driver) and branches in Odoo first.', bad: true);
      return;
    }
    int dest = hubs.length == 1 ? n(hubs.first['id']) : 0;
    Map<String, dynamic>? veh;
    Map<String, dynamic>? drv = Session.i.role == 'loader' ? Session.i.staff : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('New trip'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<int>(
                value: dest == 0 ? null : dest,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Final stop'),
                items: [for (final h in hubs) DropdownMenuItem(value: n(h['id']), child: Text('${h['name']} (${h['code']})'))],
                onChanged: (v) => set(() => dest = v ?? 0),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                value: veh == null ? null : n(veh!['id']),
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Vehicle'),
                items: [for (final v in m.vehicles) DropdownMenuItem(value: n(v['id']), child: Text('${v['name']} ${s(v['description'])}'))],
                onChanged: (v) => set(() => veh = m.vehicles.firstWhere((x) => n(x['id']) == v)),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                value: drv == null ? null : n(drv!['id']),
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Driver / custodian'),
                items: [for (final x in drivers) DropdownMenuItem(value: n(x['id']), child: Text(s(x['name'])))],
                onChanged: (v) => set(() => drv = drivers.firstWhere((x) => n(x['id']) == v)),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: dest == 0 || veh == null || drv == null ? null : () => Navigator.pop(ctx, true),
              child: const Text('Start loading'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final mf = await Ops.openManifest(dest: dest, vehicle: veh!, driver: drv!);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LoadingPage(m: mf)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Load vehicle')),
      floatingActionButton: FloatingActionButton.extended(onPressed: _new, icon: const Icon(Icons.add), label: const Text('New trip')),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: box(color: C.amberLight, border: false),
          child: Text('$_waiting parcel${_waiting == 1 ? '' : 's'} at ${Master.i.hubName} waiting to be loaded.', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        const Label('Trips being loaded'),
        if (_open.isEmpty) const Empty(Icons.local_shipping_outlined, 'No trip being loaded. Tap New trip.'),
        for (final m in _open)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: box(),
            child: ListTile(
              leading: const Icon(Icons.local_shipping, color: C.ink),
              title: Text('${m['vehicle']} → ${Master.i.hubLabel(n(m['destination_hub_id']))}', style: h(15)),
              subtitle: Text('${m['name']} · ${m['driver']} · ${Ops.lines(m).length} waybills'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LoadingPage(m: m)));
                _load();
              },
            ),
          ),
        const SizedBox(height: 80),
      ]),
    );
  }
}

class LoadingPage extends StatefulWidget {
  final Map<String, dynamic> m;
  const LoadingPage({super.key, required this.m});
  @override
  State<LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends State<LoadingPage> {
  late Map<String, dynamic> m = widget.m;
  final Set<int> _okDest = {};
  String _flash = '';
  bool _flashBad = false;
  bool _busy = false;

  int get _pieces => Ops.lines(m).fold(0, (a, l) => a + piecesOf(l['loaded']).length);

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
      final w = await Db.waybill(c.name);
      final l = Ops.line(m, c.name);
      if (l != null && piecesOf(l['loaded']).contains(c.piece)) {
        _say('${c.name} piece ${c.piece} already scanned', bad: true);
        return;
      }
      if (w != null) {
        final pcs = n(w['pieces']) < 1 ? 1 : n(w['pieces']);
        if (c.piece > pcs) {
          _say('${c.name} has only $pcs piece(s)', bad: true);
          return;
        }
        if (['collected', 'cancelled'].contains(w['state'])) {
          _say('${c.name} is ${stateLabels[w['state']]}. Do not load.', bad: true);
          return;
        }
        if (s(w['manifest_no']).isNotEmpty && w['manifest_no'] != m['name'] && ['loaded', 'in_transit'].contains(w['state'])) {
          _say('${c.name} is already on ${w['manifest_no']}', bad: true);
          return;
        }
        if (n(w['current_hub_id']) != 0 && n(w['current_hub_id']) != Master.i.hubId) {
          _say('${c.name} is recorded at ${Master.i.hubLabel(n(w['current_hub_id']))}, not here', bad: true);
          return;
        }
        final dest = n(w['destination_hub_id']);
        if (dest != n(m['destination_hub_id']) && !_okDest.contains(dest)) {
          Scanner.bad();
          final go = await confirm(context, 'For ${Master.i.hubLabel(dest)}',
              'This parcel goes to ${Master.i.hubLabel(dest)}; the trip ends at ${Master.i.hubLabel(n(m['destination_hub_id']))}. Load it to drop off on the way?',
              ok: 'Load');
          if (!go) return;
          _okDest.add(dest);
        }
      } else {
        Scanner.bad();
        final go = await confirm(context, 'Not on this terminal',
            '${c.name} is not on this terminal yet (booked on another terminal that has not synced?). Load it anyway? Odoo checks it when the terminal syncs.',
            ok: 'Load anyway');
        if (!go) return;
      }
      await Ops.loadPiece(m, w, c.name, c.piece);
      m = await Db.manifest(s(m['name'])) ?? m;
      _say('✓ ${c.name}${c.piece > 1 || n(w?['pieces']) > 1 ? ' piece ${c.piece}/${n(w?['pieces']) < 1 ? 1 : n(w?['pieces'])}' : ''} loaded');
    } finally {
      _busy = false;
    }
  }

  Future<void> _remove(Map<String, dynamic> l) async {
    final loaded = piecesOf(l['loaded']).toList()..sort();
    final piece = loaded.length == 1
        ? loaded.first
        : await showModalBottomSheet<int>(
            context: context,
            builder: (ctx) => SafeArea(
              child: ListView(shrinkWrap: true, children: [
                ListTile(title: Text('Take which piece off?', style: h(16))),
                for (final p in loaded) ListTile(title: Text('${l['name']} piece $p'), onTap: () => Navigator.pop(ctx, p)),
              ]),
            ),
          );
    if (piece == null || !mounted) return;
    if (!await confirm(context, 'Take off the vehicle?', '${l['name']} piece $piece is removed from this trip.', ok: 'Take off')) return;
    await Ops.unloadPiece(m, s(l['name']), piece);
    m = await Db.manifest(s(m['name'])) ?? m;
    setState(() {});
  }

  Future<void> _depart() async {
    final ls = Ops.lines(m);
    if (ls.isEmpty) {
      toast(context, 'Scan parcels first.', bad: true);
      return;
    }
    final partial = ls.where((l) => piecesOf(l['loaded']).length < n(l['pieces'])).toList();
    final ok = await confirm(
      context,
      'Depart?',
      '${ls.length} waybills, $_pieces pieces on ${m['vehicle']} (driver ${m['driver']}).'
          '${partial.isNotEmpty ? '\n\nNot all pieces scanned for: ${partial.map((l) => '${l['name']} (${piecesOf(l['loaded']).length}/${l['pieces']})').join(', ')}' : ''}'
          '\n\nAfter departure, the driver is the custodian of every scanned piece.',
      ok: 'Depart & print manifest',
    );
    if (!ok) return;
    await Ops.depart(m);
    m = await Db.manifest(s(m['name'])) ?? m;
    final printed = await Printer.print(Docs.departure(m), 'Manifest ${m['name']}');
    if (!mounted) return;
    toast(context, printed ? 'Departed. Give the manifest slip to the driver to sign.' : 'Departed. Printer problem: print again from Track.');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ls = Ops.lines(m).reversed.toList();
    return Scaffold(
      appBar: AppBar(title: Text('${m['vehicle']} → ${Master.i.hubCodeOf(n(m['destination_hub_id']))}')),
      body: Column(children: [
        Container(
          color: C.ink,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Row(children: [
            Expanded(child: HeadStat('${ls.length}', 'waybills')),
            Expanded(child: HeadStat('$_pieces', 'pieces')),
            Expanded(child: HeadStat(kg(ls.fold<double>(0, (a, l) => a + d(l['weight']))), 'weight')),
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
          child: ls.isEmpty
              ? const Empty(Icons.qr_code_scanner, 'Scan each piece as it goes onto the vehicle.')
              : ListView(padding: const EdgeInsets.all(12), children: [
                  for (final l in ls)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: box(),
                      child: ListTile(
                        dense: true,
                        leading: Icon(piecesOf(l['loaded']).length >= n(l['pieces']) ? Icons.check_circle : Icons.timelapse,
                            color: piecesOf(l['loaded']).length >= n(l['pieces']) ? C.green : C.amber),
                        title: Text(s(l['name']), style: h(15)),
                        subtitle: Text('→ ${Master.i.hubCodeOf(n(l['destination_hub_id']))} · ${piecesOf(l['loaded']).length}/${l['pieces']} pc · ${s(l['description'])}'),
                        trailing: IconButton(tooltip: 'Take off', onPressed: () => _remove(l), icon: const Icon(Icons.remove_circle_outline)),
                      ),
                    ),
                ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(onPressed: _depart, icon: const Icon(Icons.flag_outlined), label: const Text('Finish loading & depart')),
            ),
          ),
        ),
      ]),
    );
  }
}

class HeadStat extends StatelessWidget {
  final String value, label;
  const HeadStat(this.value, this.label);
  @override
  Widget build(BuildContext context) => Column(children: [
        Text(value, style: h(24, color: Colors.white)),
        Text(label, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12.5)),
      ]);
}
