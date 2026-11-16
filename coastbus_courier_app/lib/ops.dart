import 'db.dart';
import 'fmt.dart';
import 'master.dart';
import 'session.dart';
import 'sync.dart';

Set<int> piecesOf(Object? text) => s(text).split(',').where((e) => e.trim().isNotEmpty).map((e) => int.tryParse(e.trim()) ?? 0).where((e) => e > 0).toSet();
String piecesText(Set<int> p) => (p.toList()..sort()).join(',');

/// Everything the terminal does: saved locally first (works offline), then queued for Odoo.
class Ops {
  static Future<int> _next(String key) async {
    final v = (int.tryParse(await Db.kv(key) ?? '') ?? 0) + 1;
    await Db.setKv(key, '$v');
    return v;
  }

  static Future<String> nextWaybillNo() async {
    final m = Master.i;
    return '${m.prefix}-${m.hubCode}-${m.deviceNo.toString().padLeft(2, '0')}-${(await _next('wb_seq')).toString().padLeft(5, '0')}';
  }

  static Future<String> nextManifestNo() async {
    final m = Master.i;
    return 'MNF-${m.hubCode}-${m.deviceNo.toString().padLeft(2, '0')}-${(await _next('mnf_seq')).toString().padLeft(4, '0')}';
  }

  static Future<void> _queue(String kind, Map<String, dynamic> data, String ref) async {
    await Db.queue(kind, {...data, 'staff_id': Session.i.id, 'at': data['at'] ?? utcNow()}, ref: ref, id: uuid4());
    Sync.i.changed();
    Sync.i.soon();
  }

  // ---------------------------------------------------------------- booking
  static Future<Map<String, dynamic>> book(Map<String, dynamic> f) async {
    final manual = s(f['name']).trim().toUpperCase();
    if (manual.isNotEmpty && await Db.waybill(manual) != null) throw Exception('Waybill $manual is already used on this terminal.');
    final name = manual.isNotEmpty ? manual : await nextWaybillNo();
    final hub = Master.i.hubId;
    final otp = otp6();
    final now = utcNow();
    final w = <String, dynamic>{
      ...f,
      'name': name, 'uuid': uuid4(), 'tracking_token': randomToken(10), 'state': 'booked', 'origin_hub_id': hub, 'current_hub_id': hub,
      'booked_at': now, 'booked_by': Session.i.name, 'booked_by_id': Session.i.id, 'otp_hash': otpHash(otp, name),
      'paid': ['cash', 'mpesa_code', 'mpesa_stk'].contains(f['payment_mode']), 'manifest_no': '',
    };
    await Db.putWaybill(w, local: true);
    await _queue('book', {...w, 'otp': otp, 'at': now}, name);
    return w;
  }

  static Future<void> cancel(Map<String, dynamic> w, String reason) async {
    w['state'] = 'cancelled';
    await Db.putWaybill(w);
    await _queue('cancel', {'waybill': w['name'], 'reason': reason}, s(w['name']));
  }

  // ---------------------------------------------------------------- loading
  static Future<Map<String, dynamic>> openManifest({required int dest, required Map<String, dynamic> vehicle, required Map<String, dynamic> driver}) async {
    final m = <String, dynamic>{
      'name': await nextManifestNo(), 'uuid': uuid4(), 'state': 'loading', 'origin_hub_id': Master.i.hubId, 'destination_hub_id': dest,
      'vehicle_id': vehicle['id'], 'vehicle': vehicle['name'], 'driver_id': driver['id'], 'driver': driver['name'], 'opened_at': utcNow(),
      'dispatcher': Session.i.name, 'lines': <Map<String, dynamic>>[],
    };
    await Db.putManifest(m, local: true);
    await _queue('manifest_open', {'uuid': m['uuid'], 'name': m['name'], 'destination_hub_id': dest, 'vehicle_id': vehicle['id'], 'driver_id': driver['id']},
        s(m['name']));
    return m;
  }

  static List<Map<String, dynamic>> lines(Map<String, dynamic> m) =>
      ((m['lines'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  static Map<String, dynamic>? line(Map<String, dynamic> m, String wb) {
    for (final l in lines(m)) {
      if (l['name'] == wb) return l;
    }
    return null;
  }

  static Future<void> _setLine(Map<String, dynamic> m, Map<String, dynamic> l) async {
    final all = lines(m);
    final i = all.indexWhere((x) => x['name'] == l['name']);
    if (i >= 0) {
      all[i] = l;
    } else {
      all.add(l);
    }
    m['lines'] = all;
    await Db.putManifest(m);
  }

  static Future<void> loadPiece(Map<String, dynamic> m, Map<String, dynamic>? w, String wbName, int piece) async {
    final l = line(m, wbName) ??
        {'name': wbName, 'pieces': n(w?['pieces']) == 0 ? 1 : n(w?['pieces']), 'destination_hub_id': n(w?['destination_hub_id']), 'loaded': '', 'received': '',
          'received_hub_id': 0, 'extra': false, 'weight': d(w?['weight']), 'description': s(w?['description']), 'loaded_at': utcNow()};
    final p = piecesOf(l['loaded'])..add(piece);
    l['loaded'] = piecesText(p);
    await _setLine(m, l);
    if (w != null) {
      w['state'] = m['state'] == 'in_transit' ? 'in_transit' : 'loaded';
      w['manifest_no'] = m['name'];
      w['vehicle'] = m['vehicle'];
      await Db.putWaybill(w);
    }
    await _queue('load', {'manifest_uuid': m['uuid'], 'manifest': m['name'], 'waybill': wbName, 'piece': piece}, wbName);
  }

  static Future<void> unloadPiece(Map<String, dynamic> m, String wbName, int piece) async {
    final l = line(m, wbName);
    if (l == null) return;
    final p = piecesOf(l['loaded'])..remove(piece);
    if (p.isEmpty) {
      m['lines'] = lines(m).where((x) => x['name'] != wbName).toList();
      await Db.putManifest(m);
      final w = await Db.waybill(wbName);
      if (w != null) {
        w['state'] = n(w['current_hub_id']) == n(w['origin_hub_id']) ? 'booked' : 'at_hub';
        w['manifest_no'] = '';
        await Db.putWaybill(w);
      }
    } else {
      l['loaded'] = piecesText(p);
      await _setLine(m, l);
    }
    await _queue('unload', {'manifest_uuid': m['uuid'], 'manifest': m['name'], 'waybill': wbName, 'piece': piece}, wbName);
  }

  static Future<void> depart(Map<String, dynamic> m) async {
    m['state'] = 'in_transit';
    m['departure_time'] = utcNow();
    await Db.putManifest(m);
    for (final l in lines(m)) {
      final w = await Db.waybill(s(l['name']));
      if (w != null) {
        w['state'] = 'in_transit';
        w['custodian'] = m['driver'];
        await Db.putWaybill(w);
      }
    }
    await _queue('depart', {'manifest_uuid': m['uuid'], 'manifest': m['name']}, s(m['name']));
  }

  // ---------------------------------------------------------------- offloading
  /// Pieces this branch must take off: those addressed here, or everything still on board at the final stop.
  static List<Map<String, dynamic>> expected(Map<String, dynamic> m, int hub) {
    final ls = lines(m).where((l) => l['extra'] != true).toList();
    if (hub == n(m['destination_hub_id'])) return ls.where((l) => n(l['received_hub_id']) == 0 || n(l['received_hub_id']) == hub).toList();
    return ls.where((l) => n(l['destination_hub_id']) == hub).toList();
  }

  static Future<void> offloadPiece(Map<String, dynamic> m, Map<String, dynamic>? w, String wbName, int piece, {bool extra = false}) async {
    final hub = Master.i.hubId;
    final l = line(m, wbName) ??
        {'name': wbName, 'pieces': n(w?['pieces']) == 0 ? 1 : n(w?['pieces']), 'destination_hub_id': n(w?['destination_hub_id']), 'loaded': '', 'received': '',
          'received_hub_id': hub, 'extra': true, 'weight': d(w?['weight']), 'description': s(w?['description'])};
    final p = piecesOf(l['received'])..add(piece);
    l['received'] = piecesText(p);
    l['received_hub_id'] = hub;
    await _setLine(m, l);
    await _queue('offload', {'manifest_uuid': m['uuid'], 'manifest': m['name'], 'waybill': wbName, 'piece': piece}, wbName);
  }

  /// Returns the shortages: line + missing pieces.
  static List<(Map<String, dynamic>, Set<int>)> shortages(Map<String, dynamic> m, int hub) {
    final out = <(Map<String, dynamic>, Set<int>)>[];
    for (final l in expected(m, hub)) {
      final miss = piecesOf(l['loaded']).difference(piecesOf(l['received']));
      if (miss.isNotEmpty) out.add((l, miss));
    }
    return out;
  }

  static Future<void> receiveComplete(Map<String, dynamic> m, {bool driverAck = false, int supervisorId = 0, String note = ''}) async {
    final hub = Master.i.hubId;
    final short = shortages(m, hub);
    final shortNames = {for (final x in short) s(x.$1['name'])};
    final now = utcNow();
    for (final l in [...expected(m, hub), ...lines(m).where((x) => x['extra'] == true && n(x['received_hub_id']) == hub)]) {
      final w = await Db.waybill(s(l['name']));
      if (w == null) continue;
      final allMissing = shortNames.contains(l['name']) && piecesOf(l['received']).isEmpty;
      if (allMissing) {
        w['state'] = 'lost';
      } else {
        w['state'] = n(w['destination_hub_id']) == hub ? 'arrived' : 'at_hub';
        w['current_hub_id'] = hub;
        w['arrived_at'] = now;
      }
      await Db.putWaybill(w);
    }
    if (hub == n(m['destination_hub_id'])) m['state'] = short.isEmpty ? 'reconciled' : 'discrepancy';
    m['received_at_$hub'] = now;
    await Db.putManifest(m);
    await _queue('receive_complete',
        {'manifest_uuid': m['uuid'], 'manifest': m['name'], 'driver_ack': driverAck, 'supervisor_id': supervisorId, 'note': note, 'at': now}, s(m['name']));
  }

  // ---------------------------------------------------------------- collection
  static Future<void> collect(Map<String, dynamic> w, {required String name, required String idNo, required String method}) async {
    w['state'] = 'collected';
    w['collected_at'] = utcNow();
    w['collected_by_name'] = name;
    await Db.putWaybill(w);
    await _queue('collect', {'waybill': w['name'], 'collector_name': name, 'collector_id_no': idNo, 'method': method}, s(w['name']));
  }
}
