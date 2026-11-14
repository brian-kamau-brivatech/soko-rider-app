import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'fmt.dart';
import 'perms.dart';

/// Everything lives in one SQLite file on this phone: the app works without internet.
class Db {
  static Database? _db;
  static const fileName = 'brv_pos_sales.db';

  static Future<Database> get() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(p.join(dir, fileName), version: 1, onCreate: (db, v) async {
      await _schema(db);
      await _seed(db);
    }, onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = OFF');
    });
    return _db!;
  }

  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Tables saved in a backup, in restore order.
  static const tables = [
    'kv', 'roles', 'users', 'categories', 'products', 'locations', 'stock', 'stock_moves', 'customers',
    'suppliers', 'accounts', 'pay_methods', 'shifts', 'sales', 'sale_lines', 'sale_payments', 'purchases',
    'purchase_lines', 'supplier_payments', 'customer_payments', 'requisitions', 'requisition_lines', 'expenses',
    'journal', 'journal_lines', 'audit',
  ];

  static Future<void> _schema(Database db) async {
    const id = 'id INTEGER PRIMARY KEY AUTOINCREMENT';
    final ddl = <String>[
      'CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT)',
      'CREATE TABLE roles($id, name TEXT NOT NULL, perms TEXT NOT NULL DEFAULT \'\', system INTEGER DEFAULT 0)',
      '''CREATE TABLE users($id, name TEXT NOT NULL, phone TEXT DEFAULT '', role_id INTEGER NOT NULL,
          pin_salt TEXT NOT NULL, pin_hash TEXT NOT NULL, active INTEGER DEFAULT 1, owner INTEGER DEFAULT 0,
          fails INTEGER DEFAULT 0, locked_until TEXT DEFAULT '', last_login TEXT DEFAULT '', created_at TEXT)''',
      'CREATE TABLE categories($id, name TEXT NOT NULL, color INTEGER DEFAULT 0)',
      '''CREATE TABLE products($id, name TEXT NOT NULL, sku TEXT DEFAULT '', barcode TEXT DEFAULT '',
          category_id INTEGER, price REAL NOT NULL DEFAULT 0, cost REAL NOT NULL DEFAULT 0,
          tax_rate REAL NOT NULL DEFAULT 16, unit TEXT DEFAULT 'pcs', track INTEGER DEFAULT 1,
          reorder REAL DEFAULT 0, active INTEGER DEFAULT 1, created_at TEXT)''',
      'CREATE TABLE locations($id, name TEXT NOT NULL, kind TEXT DEFAULT \'shop\', active INTEGER DEFAULT 1)',
      'CREATE TABLE stock(product_id INTEGER NOT NULL, location_id INTEGER NOT NULL, qty REAL NOT NULL DEFAULT 0, PRIMARY KEY(product_id, location_id))',
      '''CREATE TABLE stock_moves($id, date TEXT, product_id INTEGER, from_loc INTEGER, to_loc INTEGER,
          qty REAL, cost REAL, kind TEXT, ref TEXT, user_id INTEGER, note TEXT DEFAULT '')''',
      'CREATE INDEX moves_product ON stock_moves(product_id, date)',
      '''CREATE TABLE customers($id, name TEXT NOT NULL, phone TEXT DEFAULT '', email TEXT DEFAULT '',
          tax_pin TEXT DEFAULT '', credit_limit REAL DEFAULT 0, active INTEGER DEFAULT 1, created_at TEXT)''',
      '''CREATE TABLE suppliers($id, name TEXT NOT NULL, phone TEXT DEFAULT '', email TEXT DEFAULT '',
          tax_pin TEXT DEFAULT '', active INTEGER DEFAULT 1, created_at TEXT)''',
      '''CREATE TABLE accounts($id, code TEXT, name TEXT NOT NULL, type TEXT NOT NULL, skey TEXT DEFAULT '',
          active INTEGER DEFAULT 1)''',
      '''CREATE TABLE pay_methods($id, name TEXT NOT NULL, kind TEXT NOT NULL, account_id INTEGER,
          active INTEGER DEFAULT 1)''',
      '''CREATE TABLE shifts($id, number TEXT, user_id INTEGER, location_id INTEGER, opened_at TEXT, closed_at TEXT,
          opening_cash REAL DEFAULT 0, expected_cash REAL DEFAULT 0, counted_cash REAL DEFAULT 0, diff REAL DEFAULT 0,
          state TEXT DEFAULT 'open', note TEXT DEFAULT '')''',
      '''CREATE TABLE sales($id, number TEXT, date TEXT, day TEXT, user_id INTEGER, shift_id INTEGER,
          location_id INTEGER, customer_id INTEGER, net REAL, tax REAL, discount REAL, total REAL, cost REAL,
          paid REAL, change REAL, kind TEXT DEFAULT 'sale', ref_sale_id INTEGER, state TEXT DEFAULT 'done',
          note TEXT DEFAULT '', copies INTEGER DEFAULT 0)''',
      'CREATE INDEX sales_day ON sales(day)',
      '''CREATE TABLE sale_lines($id, sale_id INTEGER, product_id INTEGER, name TEXT, qty REAL, price REAL,
          discount REAL DEFAULT 0, tax_rate REAL, tax REAL, total REAL, cost REAL)''',
      'CREATE INDEX lines_sale ON sale_lines(sale_id)',
      'CREATE TABLE sale_payments($id, sale_id INTEGER, method_id INTEGER, amount REAL, ref TEXT DEFAULT \'\')',
      '''CREATE TABLE purchases($id, number TEXT, date TEXT, supplier_id INTEGER, location_id INTEGER,
          state TEXT DEFAULT 'draft', total REAL DEFAULT 0, user_id INTEGER, note TEXT DEFAULT '', received_at TEXT,
          supplier_ref TEXT DEFAULT '')''',
      'CREATE TABLE purchase_lines($id, purchase_id INTEGER, product_id INTEGER, name TEXT, qty REAL, cost REAL, total REAL)',
      '''CREATE TABLE supplier_payments($id, date TEXT, supplier_id INTEGER, purchase_id INTEGER, method_id INTEGER,
          amount REAL, ref TEXT DEFAULT '', user_id INTEGER, shift_id INTEGER)''',
      '''CREATE TABLE customer_payments($id, date TEXT, customer_id INTEGER, method_id INTEGER, amount REAL,
          ref TEXT DEFAULT '', user_id INTEGER, shift_id INTEGER)''',
      '''CREATE TABLE requisitions($id, number TEXT, date TEXT, from_loc INTEGER, to_loc INTEGER,
          state TEXT DEFAULT 'pending', user_id INTEGER, approved_by INTEGER, approved_at TEXT, note TEXT DEFAULT '')''',
      'CREATE TABLE requisition_lines($id, requisition_id INTEGER, product_id INTEGER, qty REAL, qty_sent REAL DEFAULT 0)',
      '''CREATE TABLE expenses($id, date TEXT, account_id INTEGER, method_id INTEGER, amount REAL, note TEXT DEFAULT '',
          user_id INTEGER, shift_id INTEGER)''',
      'CREATE TABLE journal($id, date TEXT, ref TEXT, memo TEXT, kind TEXT, user_id INTEGER)',
      '''CREATE TABLE journal_lines($id, journal_id INTEGER, account_id INTEGER, debit REAL DEFAULT 0,
          credit REAL DEFAULT 0, partner TEXT DEFAULT '')''',
      'CREATE INDEX jl_account ON journal_lines(account_id)',
      'CREATE TABLE audit($id, date TEXT, user_id INTEGER, action TEXT, detail TEXT)',
    ];
    for (final sql in ddl) {
      await db.execute(sql);
    }
  }

  /// Chart of accounts (code, name, type, system key).
  static const chart = <(String, String, String, String)>[
    ('1000', 'Cash', 'asset', 'cash'),
    ('1010', 'M-Pesa', 'asset', 'mpesa'),
    ('1020', 'Bank / Card', 'asset', 'bank'),
    ('1100', 'Customers (receivable)', 'asset', 'ar'),
    ('1200', 'Inventory (stock)', 'asset', 'inventory'),
    ('2000', 'Suppliers (payable)', 'liability', 'ap'),
    ('2100', 'VAT payable', 'liability', 'vat'),
    ('3000', 'Owner\'s capital', 'equity', 'equity'),
    ('4000', 'Sales', 'income', 'sales'),
    ('4900', 'Cash over', 'income', 'cash_over'),
    ('5000', 'Cost of goods sold', 'expense', 'cogs'),
    ('5100', 'Stock losses / adjustments', 'expense', 'stock_loss'),
    ('5900', 'Cash short', 'expense', 'cash_short'),
    ('6000', 'Rent', 'expense', ''),
    ('6010', 'Salaries and wages', 'expense', ''),
    ('6020', 'Electricity and water', 'expense', ''),
    ('6030', 'Transport', 'expense', ''),
    ('6040', 'Airtime and internet', 'expense', ''),
    ('6050', 'Repairs and maintenance', 'expense', ''),
    ('6090', 'General expenses', 'expense', ''),
  ];

  static Future<void> _seed(Database db) async {
    for (final r in P.defaults) {
      await db.insert('roles', {'name': r.$1, 'perms': r.$2.join(','), 'system': r.$1 == 'Owner' ? 1 : 0});
    }
    await db.insert('locations', {'name': 'Main Store', 'kind': 'store'});
    await db.insert('locations', {'name': 'Shop', 'kind': 'shop'});
    await db.insert('categories', {'name': 'General', 'color': 0});
    final acc = <String, int>{};
    for (final a in chart) {
      acc[a.$4.isEmpty ? a.$1 : a.$4] =
          await db.insert('accounts', {'code': a.$1, 'name': a.$2, 'type': a.$3, 'skey': a.$4});
    }
    await db.insert('pay_methods', {'name': 'Cash', 'kind': 'cash', 'account_id': acc['cash']});
    await db.insert('pay_methods', {'name': 'M-Pesa', 'kind': 'mpesa', 'account_id': acc['mpesa']});
    await db.insert('pay_methods', {'name': 'Card', 'kind': 'card', 'account_id': acc['bank']});
    await db.insert('pay_methods', {'name': 'Credit (customer account)', 'kind': 'credit', 'account_id': acc['ar']});
  }

  // ---------------------------------------------------------------------------
  // Small helpers
  // ---------------------------------------------------------------------------
  static Future<List<Map<String, Object?>>> q(String sql, [List<Object?> args = const []]) async =>
      (await get()).rawQuery(sql, args);

  static Future<Map<String, Object?>?> one(String sql, [List<Object?> args = const []]) async {
    final r = await q(sql, args);
    return r.isEmpty ? null : r.first;
  }

  static Future<double> sum(String sql, [List<Object?> args = const []]) async {
    final r = await one(sql, args);
    return r == null ? 0.0 : d(r.values.first);
  }

  static Future<int> count(String sql, [List<Object?> args = const []]) async {
    final r = await one(sql, args);
    return r == null ? 0 : n(r.values.first);
  }

  static Future<String?> kv(String k) async {
    final v = s((await one('SELECT v FROM kv WHERE k = ?', [k]))?['v']);
    return v.isEmpty ? null : v;
  }

  static Future<void> setKv(String k, String v) async =>
      (await get()).insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Next number in a series: S-000001, PO-0001 ...
  static Future<String> nextNumber(DatabaseExecutor tx, String series, String prefix, int width) async {
    final r = await tx.rawQuery('SELECT v FROM kv WHERE k = ?', ['seq_$series']);
    final next = (r.isEmpty ? 0 : n(r.first['v'])) + 1;
    await tx.insert('kv', {'k': 'seq_$series', 'v': '$next'}, conflictAlgorithm: ConflictAlgorithm.replace);
    return '$prefix${next.toString().padLeft(width, '0')}';
  }

  static Future<int> account(DatabaseExecutor tx, String key) async {
    final r = await tx.rawQuery('SELECT id FROM accounts WHERE skey = ? LIMIT 1', [key]);
    if (r.isEmpty) throw StateError('Account $key is missing');
    return n(r.first['id']);
  }

  static Future<void> audit(DatabaseExecutor tx, int userId, String action, String detail) async =>
      tx.insert('audit', {'date': nowIso(), 'user_id': userId, 'action': action, 'detail': detail});
}
