import 'dart:convert';
import 'db.dart';
import 'fmt.dart';

/// Branches, tariffs, vehicles, staff, settings: received from Odoo, kept for offline use.
class Master {
  static final Master i = Master._();
  Master._();

  Map<String, dynamic> raw = {};
  Map<String, dynamic> get cfg => Map<String, dynamic>.from(raw['cfg'] as Map? ?? {});
  Map<String, dynamic> get company => Map<String, dynamic>.from(raw['company'] as Map? ?? {});
  Map<String, dynamic> get device => Map<String, dynamic>.from(raw['device'] as Map? ?? {});
  List<Map<String, dynamic>> _list(String k) => ((raw[k] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  List<Map<String, dynamic>> get hubs => _list('hubs');
  List<Map<String, dynamic>> get routes => _list('routes');
  List<Map<String, dynamic>> get vehicles => _list('vehicles');
  List<Map<String, dynamic>> get staff => _list('staff').where((e) => e['active'] != false).toList();
  List<Map<String, dynamic>> get accounts => _list('accounts');

  bool get loaded => raw.isNotEmpty;
  int get hubId => n(device['hub_id']);
  int get deviceNo => n(device['number']);
  Map<String, dynamic> get hub => hubById(hubId);
  String get hubCode => s(hub['code']);
  String get hubName => s(hub['name']);
  String get prefix => s(cfg['wb_prefix']).isEmpty ? 'CB' : s(cfg['wb_prefix']);
  bool flag(String k) => cfg[k] == true;
  double num_(String k, [double def = 0]) => cfg[k] == null ? def : d(cfg[k]);

  Map<String, dynamic> hubById(int id) => hubs.firstWhere((h) => n(h['id']) == id, orElse: () => {'id': id, 'name': '?', 'code': '?'});
  String hubLabel(int id) => s(hubById(id)['name']);
  String hubCodeOf(int id) => s(hubById(id)['code']);
  Map<String, dynamic>? staffById(int id) {
    for (final st in _list('staff')) {
      if (n(st['id']) == id) return st;
    }
    return null;
  }

  String staffName(int id) => s(staffById(id)?['name']);
  Map<String, dynamic>? vehicleById(int id) {
    for (final v in vehicles) {
      if (n(v['id']) == id) return v;
    }
    return null;
  }

  /// Tariff for a route (or the opposite direction when "both ways").
  Map<String, dynamic>? route(int origin, int dest) {
    for (final r in routes) {
      if (n(r['origin_hub_id']) == origin && n(r['destination_hub_id']) == dest) return r;
    }
    for (final r in routes) {
      if (n(r['origin_hub_id']) == dest && n(r['destination_hub_id']) == origin && r['both_ways'] == true) return r;
    }
    return null;
  }

  /// Destinations that have a tariff from this branch.
  List<Map<String, dynamic>> destinations() => hubs.where((h) => n(h['id']) != hubId && route(hubId, n(h['id'])) != null).toList();

  Future<void> load() async {
    final j = await Db.kv('bootstrap');
    raw = j == null ? {} : Map<String, dynamic>.from(jsonDecode(j) as Map);
  }

  Future<void> save(Map<String, dynamic> j) async {
    raw = j;
    await Db.setKv('bootstrap', jsonEncode(j));
    await Db.setKv('bootstrap_at', DateTime.now().toIso8601String());
  }
}
