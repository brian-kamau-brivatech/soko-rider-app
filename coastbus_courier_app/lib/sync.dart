import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'db.dart';
import 'fmt.dart';
import 'master.dart';

/// Sends what the terminal did (outbox) and receives what changed for this branch. Runs every 30 s and after each action.
class Sync extends ChangeNotifier {
  static final Sync i = Sync._();
  Sync._();

  bool busy = false;
  bool online = false;
  bool revoked = false;
  String error = '';
  DateTime? lastOk;
  int pending = 0;
  int failed = 0;
  int version = 0; // bumped when data changed (screens reload)
  Timer? _timer, _soon;

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    Api.token = p.getString('token') ?? '';
    await Master.i.load();
    await counts();
  }

  bool get activated => Api.token.isNotEmpty;

  Future<void> saveActivation(String token) async {
    final p = await SharedPreferences.getInstance();
    await p.remove('server');
    await p.setString('token', token);
    Api.token = token;
    revoked = false;
  }

  Future<void> forget() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('token');
    Api.token = '';
    notifyListeners();
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => run());
    run();
  }

  void soon() {
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 800), run);
  }

  void changed() {
    version++;
    notifyListeners();
  }

  Future<void> counts() async {
    pending = await Db.count("SELECT COUNT(*) FROM outbox WHERE status = 'pending'");
    failed = await Db.count("SELECT COUNT(*) FROM outbox WHERE status = 'failed'");
  }

  Future<void> bootstrap() async {
    final j = await Api.call('GET', '/bootstrap');
    await Master.i.save(j);
    // numbering continues after a reinstall
    final dev = Map<String, dynamic>.from(j['device'] as Map);
    for (final k in [('wb_seq', 'last_waybill_seq'), ('mnf_seq', 'last_manifest_seq')]) {
      final mine = int.tryParse(await Db.kv(k.$1) ?? '') ?? 0;
      if (n(dev[k.$2]) > mine) await Db.setKv(k.$1, '${n(dev[k.$2])}');
    }
  }

  Future<bool> run({bool full = false}) async {
    if (busy || !activated) return false;
    busy = true;
    notifyListeners();
    var changedData = false;
    try {
      final at = DateTime.tryParse(await Db.kv('bootstrap_at') ?? '');
      if (full || !Master.i.loaded || at == null || DateTime.now().difference(at).inMinutes >= 10) {
        await bootstrap();
        changedData = true;
      }
      final db = await Db.get();
      for (var round = 0; round < 20; round++) {
        final out = await db.rawQuery("SELECT * FROM outbox WHERE status = 'pending' ORDER BY seq LIMIT 80");
        final events = [for (final o in out) {'uuid': o['uuid'], 'kind': o['kind'], 'data': jsonDecode(o['data'] as String)}];
        final since = await Db.kv('since') ?? '';
        final r = await Api.call('POST', '/sync', body: {'events': events, 'since': since}, timeoutSec: 60);
        var progress = 0;
        for (final res in (r['results'] as List? ?? const [])) {
          final m = Map<String, dynamic>.from(res as Map);
          if (m['ok'] == true) {
            await db.delete('outbox', where: 'uuid = ?', whereArgs: [m['uuid']]);
            progress++;
          } else if (m['retry'] == true) {
            await db.rawUpdate('UPDATE outbox SET tries = tries + 1, error = ? WHERE uuid = ?', [s(m['error']), m['uuid']]);
          } else {
            await db.rawUpdate("UPDATE outbox SET status = 'failed', error = ? WHERE uuid = ?", [s(m['error']), m['uuid']]);
            progress++;
          }
        }
        if (await _apply(r)) changedData = true;
        await Db.setKv('since', s(r['since']));
        if (progress > 0) changedData = true;
        if (out.length < 80 || progress == 0) break;
      }
      online = true;
      revoked = false;
      error = '';
      lastOk = DateTime.now();
      return true;
    } on NetError catch (e) {
      online = !e.offline && e.status != 401;
      if (e.status == 401) revoked = true;
      error = e.message;
      return false;
    } catch (e) {
      error = '$e';
      return false;
    } finally {
      await counts();
      busy = false;
      if (changedData) version++;
      notifyListeners();
    }
  }

  /// Server copies replace local ones, except records the terminal changed and has not yet sent.
  Future<bool> _apply(Map<String, dynamic> r) async {
    final db = await Db.get();
    final busyRefs = (await db.rawQuery("SELECT DISTINCT ref FROM outbox WHERE status = 'pending'")).map((e) => s(e['ref'])).toSet();
    var any = false;
    for (final x in (r['waybills'] as List? ?? const [])) {
      final w = Map<String, dynamic>.from(x as Map);
      if (busyRefs.contains(w['name'])) continue;
      await Db.putWaybill(w);
      any = true;
    }
    for (final x in (r['manifests'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(x as Map);
      if (busyRefs.contains(m['name'])) continue;
      await Db.putManifest(m);
      any = true;
    }
    return any;
  }
}
