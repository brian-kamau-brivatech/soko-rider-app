import 'dart:convert';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Local store: everything the terminal needs to work offline.
class Db {
  static Database? _db;

  static Future<Database> get() async {
    return _db ??= await openDatabase(
      join(await getDatabasesPath(), 'coastbus_courier.db'),
      version: 1,
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT)');
        await db.execute('''CREATE TABLE waybills(name TEXT PRIMARY KEY, uuid TEXT, state TEXT, origin INTEGER, dest INTEGER, cur INTEGER,
            receiver_phone TEXT, sender_phone TEXT, token TEXT, booked_at TEXT, booked_by INTEGER, manifest TEXT, local INTEGER DEFAULT 0, data TEXT)''');
        await db.execute('CREATE INDEX wb_state ON waybills(state, dest)');
        await db.execute('CREATE INDEX wb_rphone ON waybills(receiver_phone)');
        await db.execute('CREATE INDEX wb_sphone ON waybills(sender_phone)');
        await db.execute('CREATE INDEX wb_token ON waybills(token)');
        await db.execute('CREATE INDEX wb_booked ON waybills(booked_at)');
        await db.execute('''CREATE TABLE manifests(name TEXT PRIMARY KEY, uuid TEXT, state TEXT, origin INTEGER, dest INTEGER,
            local INTEGER DEFAULT 0, updated TEXT, data TEXT)''');
        await db.execute('''CREATE TABLE outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT UNIQUE, kind TEXT, ref TEXT, data TEXT,
            status TEXT DEFAULT 'pending', error TEXT DEFAULT '', created TEXT, tries INTEGER DEFAULT 0)''');
      },
    );
  }

  static Future<String?> kv(String k) async {
    final r = await (await get()).rawQuery('SELECT v FROM kv WHERE k = ?', [k]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  static Future<void> setKv(String k, String v) async =>
      (await get()).insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);

  static Future<int> count(String sql, [List<Object?> a = const []]) async =>
      Sqflite.firstIntValue(await (await get()).rawQuery(sql, a)) ?? 0;

  // -------------------------------------------------------------- waybills
  static Map<String, dynamic> _wb(Map<String, Object?> r) => Map<String, dynamic>.from(jsonDecode(r['data'] as String) as Map);

  static Future<Map<String, dynamic>?> waybill(String name) async {
    final r = await (await get()).rawQuery('SELECT data FROM waybills WHERE name = ?', [name]);
    return r.isEmpty ? null : _wb(r.first);
  }

  static Future<Map<String, dynamic>?> waybillByToken(String token) async {
    final r = await (await get()).rawQuery('SELECT data FROM waybills WHERE token = ?', [token]);
    return r.isEmpty ? null : _wb(r.first);
  }

  static Future<List<Map<String, dynamic>>> waybills(String where, [List<Object?> a = const [], String order = 'booked_at DESC', int limit = 500]) async {
    final r = await (await get()).rawQuery('SELECT data FROM waybills WHERE $where ORDER BY $order LIMIT $limit', a);
    return r.map(_wb).toList();
  }

  static Future<void> putWaybill(Map<String, dynamic> w, {bool local = false}) async {
    await (await get()).insert(
        'waybills',
        {
          'name': w['name'], 'uuid': w['uuid'] ?? '', 'state': w['state'], 'origin': w['origin_hub_id'], 'dest': w['destination_hub_id'],
          'cur': w['current_hub_id'] ?? 0, 'receiver_phone': w['receiver_phone'] ?? '', 'sender_phone': w['sender_phone'] ?? '',
          'token': w['tracking_token'] ?? '', 'booked_at': w['booked_at'] ?? '', 'booked_by': w['booked_by_id'] ?? 0,
          'manifest': w['manifest_no'] ?? '', 'local': local ? 1 : 0, 'data': jsonEncode(w),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // -------------------------------------------------------------- manifests
  static Future<Map<String, dynamic>?> manifest(String name) async {
    final r = await (await get()).rawQuery('SELECT data FROM manifests WHERE name = ?', [name]);
    return r.isEmpty ? null : Map<String, dynamic>.from(jsonDecode(r.first['data'] as String) as Map);
  }

  static Future<List<Map<String, dynamic>>> manifests(String where, [List<Object?> a = const []]) async {
    final r = await (await get()).rawQuery('SELECT data FROM manifests WHERE $where ORDER BY updated DESC LIMIT 200', a);
    return r.map((e) => Map<String, dynamic>.from(jsonDecode(e['data'] as String) as Map)).toList();
  }

  static Future<void> putManifest(Map<String, dynamic> m, {bool local = false}) async {
    await (await get()).insert(
        'manifests',
        {
          'name': m['name'], 'uuid': m['uuid'] ?? '', 'state': m['state'], 'origin': m['origin_hub_id'], 'dest': m['destination_hub_id'],
          'local': local ? 1 : 0, 'updated': DateTime.now().toIso8601String(), 'data': jsonEncode(m),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // -------------------------------------------------------------- outbox
  static Future<void> queue(String kind, Map<String, dynamic> data, {String ref = '', String? id}) async {
    await (await get()).insert('outbox', {
      'uuid': id ?? data['uuid'] ?? '', 'kind': kind, 'ref': ref, 'data': jsonEncode(data), 'created': DateTime.now().toIso8601String(),
    });
  }
}
