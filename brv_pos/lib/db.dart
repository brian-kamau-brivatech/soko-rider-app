import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Everything BRV POS keeps lives in one SQLite file on this device.
class Db {
  static Database? _db;

  static Future<Database> get() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(p.join(dir, 'brv_pos.db'), version: 3, onUpgrade: (db, oldV, newV) async {
      if (oldV < 2) await _v2(db);
      if (oldV < 3) await _v3(db);
    }, onCreate: (db, v) async {
      await db.execute('''CREATE TABLE items(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        price REAL NOT NULL,           -- unit price incl. VAT
        tax TEXT NOT NULL,             -- A..E
        cls_cd TEXT NOT NULL,          -- KRA item classification
        item_type TEXT NOT NULL,       -- 1 raw, 2 finished, 3 service
        origin TEXT NOT NULL,
        pkg_unit TEXT NOT NULL,
        qty_unit TEXT NOT NULL,
        barcode TEXT DEFAULT '',
        item_cd TEXT DEFAULT '',
        registered INTEGER DEFAULT 0,
        reg_error TEXT DEFAULT '',
        active INTEGER DEFAULT 1,
        created_at TEXT)''');
      await db.execute('''CREATE TABLE sales(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        invc_no INTEGER NOT NULL,
        trd_invc_no TEXT NOT NULL,
        kind TEXT NOT NULL,            -- S sale, R credit note
        org_invc_no INTEGER DEFAULT 0,
        rfd_rsn TEXT DEFAULT '',
        status TEXT NOT NULL,          -- signed | pending | failed
        created_at TEXT NOT NULL,      -- local ISO time
        day TEXT NOT NULL,             -- yyyy-MM-dd for reports
        cust_tin TEXT DEFAULT '', cust_nm TEXT DEFAULT '', cust_mbl TEXT DEFAULT '',
        pmt_ty_cd TEXT NOT NULL,
        tendered REAL DEFAULT 0,
        tot_taxbl REAL, tot_tax REAL, tot_amt REAL, item_cnt INTEGER,
        cashier TEXT DEFAULT '',
        payload TEXT, response TEXT,
        rcpt_no INTEGER, tot_rcpt_no INTEGER,
        intrl_data TEXT DEFAULT '', rcpt_sign TEXT DEFAULT '',
        sdc_id TEXT DEFAULT '', mrc_no TEXT DEFAULT '', sdc_date TEXT DEFAULT '',
        error TEXT DEFAULT '',
        copies INTEGER DEFAULT 0)''');
      await db.execute('CREATE INDEX sales_day ON sales(day)');
      await db.execute('''CREATE TABLE sale_lines(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_id INTEGER NOT NULL,
        item_id INTEGER, item_cd TEXT, name TEXT, tax TEXT,
        qty REAL, price REAL, dc_rt REAL DEFAULT 0, dc_amt REAL DEFAULT 0,
        taxbl REAL, tax_amt REAL, tot REAL)''');
      await db.execute('CREATE INDEX lines_sale ON sale_lines(sale_id)');
      await db.execute('CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT)');
      await db.execute('CREATE TABLE item_classes(cd TEXT PRIMARY KEY, nm TEXT, lvl INTEGER, tax TEXT)');
      await db.execute('''CREATE TABLE calls(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT, request TEXT, response TEXT, ok INTEGER, code TEXT, msg TEXT, ms INTEGER, created_at TEXT)''');
      await _v2(db);
      await _v3(db);
    });
    return _db!;
  }

  /// Version 2: users (login), customers and Z reports.
  static Future<void> _v2(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS users(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT NOT NULL UNIQUE COLLATE NOCASE,
      name TEXT NOT NULL,
      role TEXT NOT NULL,            -- admin | cashier
      salt TEXT NOT NULL,
      pass_hash TEXT NOT NULL,
      active INTEGER DEFAULT 1,
      first_login INTEGER DEFAULT 1,
      created_at TEXT)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS customers(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      tin TEXT DEFAULT '',
      phone TEXT DEFAULT '',
      email TEXT DEFAULT '',
      created_at TEXT)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS z_reports(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      z_no INTEGER NOT NULL,
      day TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL,
      closed_by TEXT DEFAULT '',
      data TEXT)''');
  }

  /// Version 3: whether KRA's eTIMS portal shows the sale (0 not checked, 1 confirmed, 2 not found yet).
  static Future<void> _v3(DatabaseExecutor db) async {
    await db.execute('ALTER TABLE sales ADD COLUMN kra_ok INTEGER DEFAULT 0');
    await db.execute("ALTER TABLE sales ADD COLUMN kra_checked TEXT DEFAULT ''");
  }

  // --- key/value (counters that must change in the same transaction as a sale) ---
  static Future<String?> kv(String k, {DatabaseExecutor? tx}) async {
    final db = tx ?? await get();
    final r = await db.query('kv', where: 'k = ?', whereArgs: [k], limit: 1);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  static Future<void> setKv(String k, String v, {DatabaseExecutor? tx}) async {
    final db = tx ?? await get();
    await db.insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<int> nextInvoiceNo({DatabaseExecutor? tx}) async =>
      int.tryParse(await kv('next_invoice_no', tx: tx) ?? '') ?? 1;

  static Future<void> setNextInvoiceNo(int n, {DatabaseExecutor? tx}) => setKv('next_invoice_no', '$n', tx: tx);

  static Future<void> logCall(String path, Object? request, Object? response, bool ok, String code, String msg, int ms) async {
    final db = await get();
    String enc(Object? o) {
      try {
        final s = jsonEncode(o);
        return s.length > 20000 ? s.substring(0, 20000) : s;
      } catch (_) {
        return '$o';
      }
    }

    await db.insert('calls', {
      'path': path,
      'request': enc(request),
      'response': enc(response),
      'ok': ok ? 1 : 0,
      'code': code,
      'msg': msg.length > 500 ? msg.substring(0, 500) : msg,
      'ms': ms,
      'created_at': DateTime.now().toIso8601String(),
    });
    // Keep the log small: last 2000 calls.
    await db.execute('DELETE FROM calls WHERE id NOT IN (SELECT id FROM calls ORDER BY id DESC LIMIT 2000)');
  }
}
