import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'bus.dart';
import 'db.dart';
import 'fmt.dart';
import 'licence.dart';
import 'net.dart';
import 'session.dart';
import 'settings.dart';

/// Offline first: everything is saved on the device at once; this sends it to the BRV server and brings
/// in what the other devices of the company did. Runs every minute, after changes, and when asked.
class Sync extends ChangeNotifier {
  Sync._();
  static final Sync i = Sync._();

  bool busy = false;
  bool online = false;
  String error = '';
  DateTime? lastOk;
  int pending = 0;
  Timer? _timer;
  Timer? _soon;
  bool _applying = false;
  final Map<String, List<String>> _cols = {};

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => run());
    dataVersion.addListener(_onLocalChange);
    run();
  }

  void _onLocalChange() {
    if (_applying) return;
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 3), run);
  }

  Future<int> countPending() async {
    pending = await Db.count('SELECT COUNT(*) FROM outbox');
    return pending;
  }

  Future<List<String>> _columns(DatabaseExecutor tx, String table) async {
    if (_cols.containsKey(table)) return _cols[table]!;
    final r = await tx.rawQuery('PRAGMA table_info($table)');
    return _cols[table] = [for (final c in r) s(c['name'])];
  }

  /// One full round: push everything waiting, then pull until up to date. Returns false when it failed.
  Future<bool> run() async {
    final lic = Licence.i;
    if (busy || !lic.linked) return false;
    busy = true;
    notifyListeners();
    try {
      final db = await Db.get();
      var pulledAny = false;
      for (var round = 0; round < 50; round++) {
        // push
        final out = await db.rawQuery('SELECT * FROM outbox ORDER BY seq LIMIT 400');
        final push = <Map<String, Object?>>[];
        final seen = <String>{};
        var maxSeq = 0;
        for (final o in out) {
          maxSeq = n(o['seq']);
          final tbl = s(o['tbl']), rid = s(o['rid']);
          if (!seen.add('$tbl/$rid')) continue;
          final rows = tbl == 'kv'
              ? await db.rawQuery('SELECT * FROM kv WHERE k = ?', [rid])
              : await db.rawQuery('SELECT * FROM $tbl WHERE id = ?', [int.tryParse(rid) ?? 0]);
          push.add(rows.isEmpty ? {'tbl': tbl, 'rid': rid, 'deleted': true} : {'tbl': tbl, 'rid': rid, 'data': rows.first});
        }
        final since = int.tryParse(await Db.kv('sync_rev') ?? '') ?? 0;
        final Map<String, dynamic> r;
        try {
          r = await Net.call(lic.server, 'POST', '/sync', body: {'since': since, 'push': push}, headers: lic.auth, timeoutSec: 40);
        } on NetError catch (e) {
          if (e.status == 401) {
            await lic.hello(); // token refresh, or the device was removed
            if (lic.status == 'revoked') throw NetError('This device was removed from the company.', status: 403);
            continue;
          }
          if (e.status == 402 || e.status == 403) {
            if (e.body['licence'] is Map) await lic.apply(Map<String, dynamic>.from(e.body['licence'] as Map));
            if (e.body['status'] == 'revoked') await lic.markRevoked();
          }
          rethrow;
        }
        if (maxSeq > 0) await db.rawDelete('DELETE FROM outbox WHERE seq <= ?', [maxSeq]);
        if (r['licence'] is Map) await lic.apply(Map<String, dynamic>.from(r['licence'] as Map));
        final pull = (r['pull'] as List? ?? const []).cast<Map>();
        if (pull.isNotEmpty) {
          await _apply(db, pull);
          pulledAny = true;
        }
        await Db.setKv('sync_rev', '${r['rev'] ?? since}');
        final morePush = await Db.count('SELECT COUNT(*) FROM outbox') > 0;
        if (r['more'] != true && !morePush) break;
      }
      online = true;
      error = '';
      lastOk = DateTime.now();
      if (pulledAny) {
        await Settings.i.load();
        await Session.i.reload();
        _applying = true;
        changed();
        _applying = false;
      }
      return true;
    } on NetError catch (e) {
      online = !e.offline;
      error = e.message;
      return false;
    } catch (e) {
      error = '$e';
      return false;
    } finally {
      await countPending();
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _apply(Database db, List<Map> rows) async {
    await db.transaction((tx) async {
      await tx.rawUpdate('UPDATE sync_state SET muted = 1');
      var moves = false;
      for (final row in rows) {
        final tbl = '${row['tbl']}';
        final rid = '${row['rid']}';
        if (tbl != 'kv' && !Db.synced.contains(tbl)) continue;
        if (tbl == 'stock_moves') moves = true;
        if (row['deleted'] == true || row['data'] == null) {
          if (tbl == 'kv') {
            await tx.delete('kv', where: 'k = ?', whereArgs: [rid]);
          } else {
            await tx.delete(tbl, where: 'id = ?', whereArgs: [int.tryParse(rid) ?? 0]);
          }
          continue;
        }
        if (tbl == 'kv' && !Db.sharedKeys.contains(rid)) continue;
        final cols = await _columns(tx, tbl);
        final data = Map<String, Object?>.from(row['data'] as Map)..removeWhere((k, v) => !cols.contains(k));
        await tx.insert(tbl, data, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (moves) await Db.rebuildStock(tx);
      await tx.rawUpdate('UPDATE sync_state SET muted = 0');
    });
  }

  String get statusText {
    if (busy) return 'Syncing...';
    if (!online && lastOk == null) return error.isEmpty ? 'Not synced yet' : 'Offline';
    if (error.isNotEmpty) return 'Offline · ${pending > 0 ? '$pending to send' : 'all saved here'}';
    if (pending > 0) return '$pending waiting to send';
    return 'Synced ${lastOk == null ? '' : '${two(lastOk!.hour)}:${two(lastOk!.minute)}'}';
  }
}
