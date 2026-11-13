import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

double dd(dynamic v) => v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);
double? dn(dynamic v) => (v == null || v == false) ? null : dd(v);
int ii(dynamic v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);
String ss(dynamic v) => (v == null || v == false) ? '' : '$v';
List<Map<String, dynamic>> ll(dynamic v) => ((v as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

class ApiError implements Exception {
  final String message;
  final bool device; // wrong / missing device PIN
  final bool cashier; // a cashier must sign in
  final bool login; // manager must sign in again
  final bool countRequired;
  ApiError(this.message, {this.device = false, this.cashier = false, this.login = false, this.countRequired = false});
  @override
  String toString() => message;
}

/// JSON-RPC to Odoo. The session cookie keeps the database (and, in the manager app, the signed-in user).
class Api {
  static String server = '';
  static String db = '';
  static String cookie = '';
  static void Function(String cookie)? onCookie;

  static String url(String path) => '${server.replaceAll(RegExp(r'/+$'), '')}$path';

  static void _keepCookie(http.Response r) {
    final raw = r.headers['set-cookie'] ?? '';
    final m = RegExp(r'session_id=([^;]+)').firstMatch(raw);
    if (m != null && m.group(1) != cookie) {
      cookie = m.group(1)!;
      onCookie?.call(cookie);
    }
  }

  /// Picks the database on this session (Odoo with several databases and no host filter).
  static Future<void> selectDb() async {
    if (db.isEmpty) return;
    try {
      final c = http.Client();
      final req = http.Request('GET', Uri.parse(url('/web/login?db=${Uri.encodeQueryComponent(db)}')))
        ..followRedirects = false
        ..headers.addAll({if (cookie.isNotEmpty) 'Cookie': 'session_id=$cookie'});
      final res = await http.Response.fromStream(await c.send(req).timeout(const Duration(seconds: 20)));
      _keepCookie(res);
      c.close();
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> call(String path, Map<String, dynamic> params, {bool retried = false}) async {
    if (server.isEmpty) throw ApiError('Set the server address first.', device: true);
    http.Response r;
    try {
      r = await http
          .post(Uri.parse(url(path)),
              headers: {'Content-Type': 'application/json', if (cookie.isNotEmpty) 'Cookie': 'session_id=$cookie'},
              body: jsonEncode({'jsonrpc': '2.0', 'method': 'call', 'params': params}))
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw ApiError('The server did not respond. Check the internet.');
    } catch (_) {
      throw ApiError('No internet connection.');
    }
    _keepCookie(r);
    if (r.statusCode == 404 && !retried && db.isNotEmpty) {
      await selectDb(); // session lost its database: pick it again and retry once
      return call(path, params, retried: true);
    }
    if (r.statusCode == 404) throw ApiError('The Utange module is not installed on this server, or the address is wrong.');
    if (r.statusCode != 200) throw ApiError('Server error (${r.statusCode}).');
    dynamic data;
    try {
      data = jsonDecode(r.body);
    } catch (_) {
      throw ApiError('Unexpected answer from the server. Check the server address.');
    }
    if (data is Map && data['error'] != null) {
      final e = data['error'];
      final d = e is Map ? e['data'] : null;
      final name = d is Map ? ss(d['name']) : '';
      final msg = d is Map ? ss(d['message']) : ss(e is Map ? e['message'] : e);
      if (name.contains('SessionExpired') || msg.contains('Session expired')) {
        throw ApiError('Please sign in again.', login: true);
      }
      throw ApiError(msg.isEmpty ? 'Server error.' : msg);
    }
    final res = Map<String, dynamic>.from((data as Map)['result'] as Map? ?? const {});
    if (res.containsKey('ok') && res['ok'] != true) {
      final msg = ss(res['error']);
      throw ApiError(msg.isEmpty ? 'Something went wrong.' : msg,
          device: res['device'] == true,
          cashier: res['cashier_required'] == true,
          login: res['denied'] == true,
          countRequired: res['count_required'] == true);
    }
    return res;
  }
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------
class PosConfigInfo {
  final int id;
  final String name;
  final bool cashiersOn;
  final bool open;
  PosConfigInfo.fromJson(Map<String, dynamic> j)
      : id = ii(j['id']),
        name = ss(j['name']),
        cashiersOn = j['cashiers_on'] == true,
        open = j['open'] == true;
}

class Cashier {
  final int id;
  final String name;
  final String role;
  final bool hasPin;
  final String job;
  Cashier.fromJson(Map<String, dynamic> j)
      : id = ii(j['id']),
        name = ss(j['name']),
        role = ss(j['role']),
        hasPin = j['has_pin'] == true,
        job = ss(j['job']);
  bool get isManager => role == 'manager';
}

class PosProduct {
  final int id;
  final String name;
  final double price;
  final String uom;
  final String barcode;
  final List<int> categIds;
  final double? qty;
  final String image;
  final String point; // bar | kitchen | ''
  PosProduct.fromJson(Map<String, dynamic> j)
      : id = ii(j['id']),
        name = ss(j['name']),
        price = dd(j['price']),
        uom = ss(j['uom']),
        barcode = ss(j['barcode']),
        categIds = ((j['categ_ids'] as List?) ?? const []).map(ii).toList(),
        qty = dn(j['qty']),
        point = ss(j['point']),
        image = Api.url(ss(j['image']));
}

class PayMethod {
  final int id;
  final String name;
  final bool cash;
  final bool mpesa;
  final bool account;
  PayMethod.fromJson(Map<String, dynamic> j)
      : id = ii(j['id']),
        name = ss(j['name']),
        cash = j['cash'] == true,
        mpesa = j['mpesa'] == true,
        account = j['account'] == true;
}

class PosSetup {
  final String configName;
  final bool sessionOpen;
  final String sessionName;
  final List<PayMethod> methods;
  final List<Map<String, dynamic>> categories;
  final List<PosProduct> products;
  final int companyId;
  final String shopName;
  final String shopPhone;
  final String shopEmail;
  final String shopVat;
  final String shopAddress;
  final String header;
  final String footer;
  final bool blockZero;
  final bool needsOpenCount;
  final String receiptPrinterIp;
  final String receiptPrinterVia; // odoo (pos_escpos) | direct | ''
  final List<KitchenPrinter> kitchenPrinters;
  final List<Map<String, dynamic>> points;
  PosSetup.fromJson(Map<String, dynamic> j)
      : configName = ss((j['config'] ?? const {})['name']),
        sessionOpen = j['session'] is Map,
        sessionName = j['session'] is Map ? ss(j['session']['name']) : '',
        methods = ll(j['payment_methods']).map(PayMethod.fromJson).toList(),
        categories = ll(j['categories']),
        products = ll(j['products']).map(PosProduct.fromJson).toList(),
        companyId = ii((j['company'] ?? const {})['id']),
        shopName = ss((j['company'] ?? const {})['name']),
        shopPhone = ss((j['company'] ?? const {})['phone']),
        shopEmail = ss((j['company'] ?? const {})['email']),
        shopVat = ss((j['company'] ?? const {})['vat']),
        shopAddress = ss((j['company'] ?? const {})['address']),
        header = ss(j['receipt_header']),
        footer = ss(j['receipt_footer']),
        blockZero = j['block_zero'] == true,
        needsOpenCount = j['needs_open_count'] == true,
        receiptPrinterIp = ss(j['receipt_printer_ip']),
        receiptPrinterVia = ss(j['receipt_printer_via']),
        kitchenPrinters = ll(j['kitchen_printers']).map(KitchenPrinter.fromJson).toList(),
        points = ll(j['points']);
}

/// An Odoo preparation (kitchen / bar) printer with a network IP.
class KitchenPrinter {
  final int id;
  final String name;
  final String ip;
  final String via;
  final List<int> categIds;
  KitchenPrinter.fromJson(Map<String, dynamic> j)
      : id = ii(j['id']),
        name = ss(j['name']),
        ip = ss(j['ip']),
        via = ss(j['via']),
        categIds = ((j['categ_ids'] as List?) ?? const []).map(ii).toList();
}

class SaleLine {
  final String name;
  final double qty;
  final double price;
  final double total;
  SaleLine.fromJson(Map<String, dynamic> j)
      : name = ss(j['name']),
        qty = dd(j['qty']),
        price = dd(j['price']),
        total = dd(j['total']);
}

class SalePayment {
  final String method;
  final double amount;
  final String ref;
  SalePayment.fromJson(Map<String, dynamic> j)
      : method = ss(j['method']),
        amount = dd(j['amount']),
        ref = ss(j['ref']);
}

class Sale {
  final int id;
  final String name;
  final String ref;
  final String date;
  final double amount;
  final double tax;
  final double change;
  final String customer;
  final String cashier;
  final int count;
  final List<SalePayment> payments;
  final List<SaleLine> lines;
  Sale.fromJson(Map<String, dynamic> j)
      : id = ii(j['id']),
        name = ss(j['name']),
        ref = ss(j['ref']),
        date = ss(j['date']),
        amount = dd(j['amount']),
        tax = dd(j['tax']),
        change = dd(j['change']),
        customer = ss(j['customer']),
        cashier = ss(j['cashier']),
        count = ii(j['count']),
        payments = ll(j['payments']).map(SalePayment.fromJson).toList(),
        lines = ll(j['lines']).map(SaleLine.fromJson).toList();
  String get time => date.length >= 16 ? date.substring(11, 16) : date;
  String get methods => payments.where((p) => p.amount > 0).map((p) => p.method).toSet().join(' + ');
}

class NameAmount {
  final String name;
  final double amount;
  final double qty;
  final int count;
  NameAmount(this.name, this.amount, {this.qty = 0, this.count = 0});
}

class SalesReport {
  final String period;
  final String from;
  final String to;
  final int count;
  final double total;
  final List<NameAmount> byMethod;
  final List<NameAmount> byCashier;
  final List<NameAmount> topProducts;
  final List<NameAmount> days;
  final List<Sale> orders;
  SalesReport.fromJson(Map<String, dynamic> j)
      : period = ss(j['period']),
        from = ss(j['from']),
        to = ss(j['to']),
        count = ii(j['count']),
        total = dd(j['total']),
        byMethod = ll(j['by_method']).map((e) => NameAmount(ss(e['method']), dd(e['amount']))).toList(),
        byCashier = ll(j['by_cashier']).map((e) => NameAmount(ss(e['name']), dd(e['total']), count: ii(e['count']))).toList(),
        topProducts = ll(j['top_products']).map((e) => NameAmount(ss(e['name']), dd(e['total']), qty: dd(e['qty']))).toList(),
        days = ll(j['days']).map((e) => NameAmount(ss(e['day']), dd(e['total']), count: ii(e['count']))).toList(),
        orders = ll(j['orders']).map(Sale.fromJson).toList();
}

class SessionClosing {
  final int orders;
  final double amount;
  final bool hasCash;
  final String cashName;
  final double cashExpected;
  final double cashOpening;
  final double cashPayments;
  final List<NameAmount> cashMoves;
  final List<NameAmount> other;
  final double? maxDifference;
  final List<String> drafts;
  SessionClosing.fromJson(Map<String, dynamic> j)
      : orders = ii(j['orders']),
        amount = dd(j['amount']),
        hasCash = j['cash'] is Map,
        cashName = j['cash'] is Map ? ss(j['cash']['name']) : '',
        cashExpected = j['cash'] is Map ? dd(j['cash']['expected']) : 0,
        cashOpening = j['cash'] is Map ? dd(j['cash']['opening']) : 0,
        cashPayments = j['cash'] is Map ? dd(j['cash']['payments']) : 0,
        cashMoves = j['cash'] is Map ? ll(j['cash']['moves']).map((e) => NameAmount(ss(e['name']), dd(e['amount']))).toList() : const [],
        other = ll(j['other']).map((e) => NameAmount(ss(e['name']), dd(e['amount']))).toList(),
        maxDifference = dn(j['max_difference']),
        drafts = ((j['drafts'] as List?) ?? const []).map(ss).toList();
}

class SessionInfo {
  final String config;
  final String state;
  final String user;
  final double openingSuggestion;
  final String sessionName;
  final String startAt;
  final String lastClosedName;
  final String lastClosedAt;
  final SessionClosing? closing;
  final bool cashiersOn;
  final String cashierName;
  final String cashierRole;
  final bool canClose;
  final bool canCashMove;
  final bool requireSheet;
  final bool countAtClose;
  final String sheetName;
  final int openDiffs;
  final bool needsOpenCount;
  SessionInfo.fromJson(Map<String, dynamic> j)
      : config = ss(j['config']),
        state = ss(j['state']),
        user = ss(j['user']),
        openingSuggestion = dd(j['opening_suggestion']),
        sessionName = j['session'] is Map ? ss(j['session']['name']) : '',
        startAt = j['session'] is Map ? ss(j['session']['start_at']) : '',
        lastClosedName = j['last_closed'] is Map ? ss(j['last_closed']['name']) : '',
        lastClosedAt = j['last_closed'] is Map ? ss(j['last_closed']['stop_at']) : '',
        closing = j['closing'] is Map ? SessionClosing.fromJson(Map<String, dynamic>.from(j['closing'] as Map)) : null,
        cashiersOn = j['cashiers_on'] == true,
        cashierName = j['cashier'] is Map ? ss(j['cashier']['name']) : '',
        cashierRole = j['cashier'] is Map ? ss(j['cashier']['role']) : '',
        canClose = j['can_close'] != false,
        canCashMove = j['can_cash_move'] != false,
        requireSheet = j['require_sheet'] == true,
        countAtClose = j['count_at_close'] == true,
        sheetName = j['sheet'] is Map ? ss(j['sheet']['name']) : '',
        openDiffs = j['sheet'] is Map ? ii(j['sheet']['open_diffs']) : 0,
        needsOpenCount = j['needs_open_count'] == true;
  bool get isOpen => state == 'opened';
  bool get isClosing => state == 'closing_control';
  bool get canOpen => state == 'closed' || state == 'opening_control';
}

/// One item to count on the stock sheet.
class CountItem {
  final int productId;
  final String name;
  final String uom;
  final String categ;
  final double price;
  final double system; // opening: Odoo's quantity in the bar
  final double? lastClose; // opening: last shift's closing count
  final double opening; // closing: opening count
  final double received;
  final double sentOut;
  final double sold;
  final double expected; // closing: what should be there
  final String point; // Bar | Kitchen | POS
  CountItem.fromJson(Map<String, dynamic> j)
      : productId = ii(j['product_id']),
        name = ss(j['name']),
        uom = ss(j['uom']),
        categ = ss(j['categ']),
        price = dd(j['price']),
        system = dd(j['system']),
        lastClose = dn(j['last_close']),
        opening = dd(j['opening']),
        received = dd(j['received']),
        sentOut = dd(j['sent_out']),
        sold = dd(j['sold']),
        expected = dd(j['expected']),
        point = ss(j['point']);
}

class Requisition {
  final int id;
  final String name;
  final String date;
  final String state;
  final String stateLabel;
  final String by;
  final String from;
  final String to;
  final String config;
  final String pointLabel;
  final String note;
  final String managerNote;
  final String transfer;
  final String approvedBy;
  final int items;
  final Map<String, dynamic>? shift;
  final List<Map<String, dynamic>> lines;
  Requisition.fromJson(Map<String, dynamic> j)
      : id = ii(j['id']),
        name = ss(j['name']),
        date = ss(j['date']),
        state = ss(j['state']),
        stateLabel = ss(j['state_label']),
        by = ss(j['by']),
        from = ss(j['from']),
        to = ss(j['to']),
        config = ss(j['config']),
        pointLabel = ss(j['point_label']),
        note = ss(j['note']).split('\n[').first,
        managerNote = ss(j['manager_note']),
        transfer = ss(j['transfer']),
        approvedBy = ss(j['approved_by']),
        items = j['items'] != null ? ii(j['items']) : ll(j['lines']).length,
        shift = j['shift'] is Map ? Map<String, dynamic>.from(j['shift'] as Map) : null,
        lines = ll(j['lines']);
}

class SheetRow {
  final int id;
  final String name;
  final String config;
  final String session;
  final String state;
  final String opened;
  final String closed;
  final String byOpen;
  final String byClose;
  final int openDiffs;
  final int closeDiffs;
  final double sales;
  final double variance;
  final bool outside;
  final String location;
  final List<Map<String, dynamic>> lines;
  SheetRow.fromJson(Map<String, dynamic> j)
      : id = ii(j['id']),
        name = ss(j['name']),
        config = ss(j['config']),
        session = ss(j['session']),
        state = ss(j['state']),
        opened = ss(j['opened']),
        closed = ss(j['closed']),
        byOpen = ss(j['by_open']),
        byClose = ss(j['by_close']),
        openDiffs = ii(j['open_diffs']),
        closeDiffs = ii(j['close_diffs']),
        sales = dd(j['sales']),
        variance = dd(j['variance']),
        outside = j['outside'] == true,
        location = ss(j['location']),
        lines = ll(j['lines']);
}
