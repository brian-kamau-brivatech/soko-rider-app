import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

double _d(dynamic v) => v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);
int _i(dynamic v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);
String _s(dynamic v) => (v == null || v == false) ? '' : '$v';

class OrderLine {
  final String name;
  final double qty;
  final String uom;
  final double total;
  OrderLine.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        qty = _d(j['qty']),
        uom = _s(j['uom']),
        total = _d(j['total']);
}

class ShopOrder {
  final int id;
  final String trackingNo;
  final String soName;
  final String source;
  final String status;
  final bool paid;
  final double amount;
  final String ago;
  final String customer;
  final String address;
  final double km;
  final double fee;
  final String items;
  final int count;
  final String rider;
  final String riderPhone;
  final bool riderAtShop;
  final String asking;
  final bool noRider;
  final bool pickedUp;
  final bool receiptReady;
  final List<OrderLine> lines;

  ShopOrder.fromJson(Map<String, dynamic> j)
      : id = _i(j['id']),
        trackingNo = _s(j['tracking_no']),
        soName = _s(j['so_name']),
        source = _s(j['source']),
        status = _s(j['status']),
        paid = j['paid'] == true,
        amount = _d(j['amount']),
        ago = _s(j['ago']),
        customer = _s(j['customer']),
        address = _s(j['address']),
        km = _d(j['km']),
        fee = _d(j['fee']),
        items = _s(j['items']),
        count = _i(j['count']),
        rider = _s(j['rider']),
        riderPhone = _s(j['rider_phone']),
        riderAtShop = j['rider_at_shop'] == true,
        asking = _s(j['asking']),
        noRider = j['no_rider'] == true,
        pickedUp = j['picked_up'] == true,
        receiptReady = j['receipt_ready'] == true,
        lines = ((j['lines'] as List?) ?? const [])
            .map((e) => OrderLine.fromJson(Map<String, dynamic>.from(e)))
            .toList();

  bool get isNew => status == 'new' || status == 'processing';
  bool get isPreparing => status == 'preparing';
  bool get isOut => status == 'out_for_delivery';
  bool get isDone => status == 'delivered';

  /// Needs someone at the shop to do something.
  bool get needsAction => (isNew && (paid && (rider.isEmpty || noRider))) || isPreparing || (isNew && !paid);

  String get statusLabel {
    if (isDone) return 'DELIVERED';
    if (isOut) return 'OUT';
    if (isPreparing) return 'PREPARING';
    if (!paid) return 'NOT PAID';
    return 'NEW';
  }

  /// One line under the order saying what is happening with the rider.
  String get riderLine {
    if (isDone) return rider.isEmpty ? 'Delivered' : 'Delivered by $rider';
    if (isOut) return rider.isEmpty ? 'On the way' : '$rider is delivering';
    if (riderAtShop) return 'Rider $rider is at the shop';
    if (rider.isNotEmpty) return pickedUp ? '$rider picked up' : '$rider is coming to the shop';
    if (asking.isNotEmpty) return 'Asking $asking…';
    if (noRider) return 'No rider found · tap to assign';
    if (!paid) return 'Waiting for M-Pesa';
    return 'Finding rider…';
  }
}

class Rider {
  final int id;
  final String name;
  final String phone;
  final String availability;
  final double km;
  final bool atShop;
  final String order;
  final String lastSeen;
  Rider.fromJson(Map<String, dynamic> j)
      : id = _i(j['id']),
        name = _s(j['name']),
        phone = _s(j['phone']),
        availability = _s(j['availability']),
        km = _d(j['km']),
        atShop = j['at_shop'] == true,
        order = _s(j['order']),
        lastSeen = _s(j['last_seen']);

  bool get isFree => availability == 'free';
  bool get isBusy => availability == 'busy';
  bool get isOffline => availability == 'offline' || availability == 'stale';
}

class Board {
  final Map<String, int> counts;
  final List<ShopOrder> orders;
  final List<Rider> riders;
  Board.fromJson(Map<String, dynamic> j)
      : counts = Map<String, dynamic>.from(j['counts'] ?? const {}).map((k, v) => MapEntry(k, _i(v))),
        orders = ((j['orders'] as List?) ?? const [])
            .map((e) => ShopOrder.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        riders = ((j['riders'] as List?) ?? const [])
            .map((e) => Rider.fromJson(Map<String, dynamic>.from(e)))
            .toList();
}

class ApiError implements Exception {
  final String message;
  final bool auth;
  ApiError(this.message, {this.auth = false});
  @override
  String toString() => message;
}

class StaffApi {
  static Future<Map<String, dynamic>> _call(String path, Map<String, dynamic> params) async {
    http.Response r;
    try {
      r = await http
          .post(Uri.parse('${AppConfig.baseUrl}$path'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'jsonrpc': '2.0', 'method': 'call', 'params': params}))
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw ApiError('The shop server did not respond.');
    } catch (_) {
      throw ApiError('No internet connection.');
    }
    if (r.statusCode != 200) throw ApiError('Server error (${r.statusCode}).');
    final data = jsonDecode(r.body);
    if (data is Map && data['error'] != null) {
      final e = data['error'];
      throw ApiError('${e is Map ? ((e['data'] is Map ? e['data']['message'] : null) ?? e['message']) : e}');
    }
    final res = Map<String, dynamic>.from((data as Map)['result'] ?? const {});
    if (res['ok'] != true) {
      final msg = _s(res['error']);
      throw ApiError(msg.isEmpty ? 'Something went wrong.' : msg, auth: msg.contains('PIN'));
    }
    return res;
  }

  static Future<String> login(String pin) async => _s((await _call('/soko/staff/login', {'pin': pin}))['shop']);

  static Future<Board> board(String pin) async => Board.fromJson(await _call('/soko/staff/board', {'pin': pin}));

  static Future<ShopOrder> order(String pin, int id) async =>
      ShopOrder.fromJson(Map<String, dynamic>.from((await _call('/soko/staff/order', {'pin': pin, 'order_id': id}))['order']));

  /// Ask one rider, or the nearest free rider when [riderId] is null.
  static Future<String> askRider(String pin, int orderId, {int? riderId}) async => _s((await _call(
      '/soko/staff/ask_rider', {'pin': pin, 'order_id': orderId, if (riderId != null) 'rider_id': riderId}))['message']);
}

// ---------------------------------------------------------------------------
// Selling (POS) — saved as real Odoo POS orders on the server.
// ---------------------------------------------------------------------------
class PosProduct {
  final int id;
  final String name;
  final double price; // tax included, as on the POS screen
  final String uom;
  final String barcode;
  final List<int> categIds;
  final double? qty;
  final String image;
  PosProduct.fromJson(Map<String, dynamic> j)
      : id = _i(j['id']),
        name = _s(j['name']),
        price = _d(j['price']),
        uom = _s(j['uom']),
        barcode = _s(j['barcode']),
        categIds = ((j['categ_ids'] as List?) ?? const []).map(_i).toList(),
        qty = j['qty'] == null || j['qty'] == false ? null : _d(j['qty']),
        image = '${AppConfig.baseUrl}${_s(j['image'])}';
}

class PayMethod {
  final int id;
  final String name;
  final bool cash;
  final bool mpesa;
  PayMethod.fromJson(Map<String, dynamic> j)
      : id = _i(j['id']),
        name = _s(j['name']),
        cash = j['cash'] == true,
        mpesa = j['mpesa'] == true;
}

class PosSetup {
  final String configName;
  final bool sessionOpen;
  final String sessionName;
  final String cashier;
  final List<PayMethod> methods;
  final List<Map<String, dynamic>> categories;
  final List<PosProduct> products;
  final String shopName;
  final String shopPhone;
  final String shopEmail;
  final String header;
  final String footer;
  PosSetup.fromJson(Map<String, dynamic> j)
      : configName = _s((j['config'] ?? const {})['name']),
        sessionOpen = j['session'] is Map,
        sessionName = j['session'] is Map ? _s(j['session']['name']) : '',
        cashier = j['session'] is Map ? _s(j['session']['user']) : '',
        methods = ((j['payment_methods'] as List?) ?? const [])
            .map((e) => PayMethod.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        categories = ((j['categories'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e)).toList(),
        products = ((j['products'] as List?) ?? const [])
            .map((e) => PosProduct.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        shopName = _s((j['company'] ?? const {})['name']),
        shopPhone = _s((j['company'] ?? const {})['phone']),
        shopEmail = _s((j['company'] ?? const {})['email']),
        header = _s(j['receipt_header']),
        footer = _s(j['receipt_footer']);
}

class SaleLine {
  final String name;
  final double qty;
  final double price;
  final double total;
  SaleLine.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        qty = _d(j['qty']),
        price = _d(j['price']),
        total = _d(j['total']);
}

class SalePayment {
  final String method;
  final double amount;
  final String ref;
  SalePayment.fromJson(Map<String, dynamic> j)
      : method = _s(j['method']),
        amount = _d(j['amount']),
        ref = _s(j['ref']);
}

class Sale {
  final int id;
  final String name;
  final String ref;
  final String date;
  final double amount;
  final double tax;
  final double paid;
  final double change;
  final String state;
  final String customer;
  final String cashier;
  final String session;
  final bool fromApp;
  final String channel; // online | walkin
  final int count;
  final List<SalePayment> payments;
  final List<SaleLine> lines;
  Sale.fromJson(Map<String, dynamic> j)
      : id = _i(j['id']),
        name = _s(j['name']),
        ref = _s(j['ref']),
        date = _s(j['date']),
        amount = _d(j['amount']),
        tax = _d(j['tax']),
        paid = _d(j['paid']),
        change = _d(j['change']),
        state = _s(j['state']),
        customer = _s(j['customer']),
        cashier = _s(j['cashier']),
        session = _s(j['session']),
        fromApp = j['from_app'] == true,
        channel = _s(j['channel']).isEmpty ? 'walkin' : _s(j['channel']),
        count = _i(j['count']),
        payments = ((j['payments'] as List?) ?? const [])
            .map((e) => SalePayment.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        lines = ((j['lines'] as List?) ?? const [])
            .map((e) => SaleLine.fromJson(Map<String, dynamic>.from(e)))
            .toList();

  String get time => date.length >= 16 ? date.substring(11, 16) : date;
  bool get isOnline => channel == 'online';
  String get methods => payments.where((p) => p.amount > 0).map((p) => p.method).toSet().join(' + ');
}

class SalesSummary {
  final int count;
  final double total;
  final List<SalePayment> byMethod;
  SalesSummary.fromJson(Map<String, dynamic> j)
      : count = _i(j['count']),
        total = _d(j['total']),
        byMethod = ((j['by_method'] as List?) ?? const [])
            .map((e) => SalePayment.fromJson({'method': e['method'], 'amount': e['amount']}))
            .toList();
}

class DayTotal {
  final String day;
  final double total;
  final double online;
  final double walkin;
  final int count;
  DayTotal.fromJson(Map<String, dynamic> j)
      : day = _s(j['day']),
        total = _d(j['total']),
        online = _d(j['online']),
        walkin = _d(j['walkin']),
        count = _i(j['count']);
}

class TopProduct {
  final String name;
  final double qty;
  final double total;
  TopProduct.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        qty = _d(j['qty']),
        total = _d(j['total']);
}

/// Sales report for a period: online orders vs walk-in.
class SalesDay {
  final String period;
  final String from;
  final String to;
  final int count;
  final double total;
  final List<SalePayment> byMethod;
  final SalesSummary online;
  final SalesSummary walkin;
  final List<DayTotal> days;
  final List<TopProduct> topProducts;
  final List<Sale> orders;
  SalesDay.fromJson(Map<String, dynamic> j)
      : period = _s(j['period']),
        from = _s(j['from']),
        to = _s(j['to']),
        count = _i(j['count']),
        total = _d(j['total']),
        byMethod = ((j['by_method'] as List?) ?? const [])
            .map((e) => SalePayment.fromJson({'method': e['method'], 'amount': e['amount']}))
            .toList(),
        online = SalesSummary.fromJson(Map<String, dynamic>.from(j['online'] ?? const {})),
        walkin = SalesSummary.fromJson(Map<String, dynamic>.from(j['walkin'] ?? const {})),
        days = ((j['days'] as List?) ?? const []).map((e) => DayTotal.fromJson(Map<String, dynamic>.from(e))).toList(),
        topProducts =
            ((j['top_products'] as List?) ?? const []).map((e) => TopProduct.fromJson(Map<String, dynamic>.from(e))).toList(),
        orders = ((j['orders'] as List?) ?? const [])
            .map((e) => Sale.fromJson(Map<String, dynamic>.from(e)))
            .toList();
}

class StockItem {
  final String name;
  final double qty;
  final double forecast;
  final String uom;
  StockItem.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        qty = _d(j['qty']),
        forecast = _d(j['forecast']),
        uom = _s(j['uom']);
}

class StockMove {
  final String date;
  final String product;
  final double qty;
  final String uom;
  final String from;
  final String to;
  final String ref;
  final bool isIn;
  final bool isOut;
  StockMove.fromJson(Map<String, dynamic> j)
      : date = _s(j['date']),
        product = _s(j['product']),
        qty = _d(j['qty']),
        uom = _s(j['uom']),
        from = _s(j['from']),
        to = _s(j['to']),
        ref = _s(j['ref']),
        isIn = j['in'] == true,
        isOut = j['out'] == true;
}

class MpesaFound {
  final bool found;
  final int txnId;
  final String receipt;
  MpesaFound(this.found, this.txnId, this.receipt);
}

class PosApi {
  static Future<Map<String, dynamic>> _c(String path, Map<String, dynamic> p) => StaffApi._call(path, p);

  static Future<PosSetup> setup(String pin) async => PosSetup.fromJson(await _c('/soko/staff/pos/setup', {'pin': pin}));

  static Future<MpesaFound> mpesaCheck(String pin, String phone, double amount, {int? dispatchId}) async {
    final r = await _c('/soko/staff/pos/mpesa_check',
        {'pin': pin, 'phone': phone, 'amount': amount, if (dispatchId != null) 'order_id': dispatchId});
    return MpesaFound(r['found'] == true, _i(r['txn_id']), _s(r['receipt']));
  }

  static Future<int> mpesaPrompt(String pin, String phone, double amount) async =>
      _i((await _c('/soko/staff/pos/mpesa_prompt', {'pin': pin, 'phone': phone, 'amount': amount}))['tx_id']);

  /// 'waiting' | 'paid' | 'cancelled' | 'failed' (+ payment found when paid)
  static Future<(String, MpesaFound)> mpesaPromptStatus(String pin, int txId, String phone, double amount) async {
    final r = await _c('/soko/staff/pos/mpesa_prompt_status', {'pin': pin, 'tx_id': txId, 'phone': phone, 'amount': amount});
    return (_s(r['state']), MpesaFound(r['found'] == true, _i(r['txn_id']), _s(r['receipt'])));
  }

  static Future<Sale> sell(String pin,
      {required String uid,
      required List<Map<String, dynamic>> lines,
      required List<Map<String, dynamic>> payments,
      String customerPhone = '',
      String customerName = ''}) async {
    final r = await _c('/soko/staff/pos/sell', {
      'pin': pin,
      'uid': uid,
      'lines': lines,
      'payments': payments,
      'customer_phone': customerPhone,
      'customer_name': customerName,
    });
    return Sale.fromJson(Map<String, dynamic>.from(r['order']));
  }

  /// period: today | yesterday | week | month; channel: online | walkin | null (all)
  static Future<SalesDay> sales(String pin, {String period = 'today', String? channel}) async => SalesDay.fromJson(
      await _c('/soko/staff/pos/sales', {'pin': pin, 'period': period, if (channel != null) 'channel': channel}));

  static Future<Sale> sale(String pin, int id) async =>
      Sale.fromJson(Map<String, dynamic>.from((await _c('/soko/staff/pos/sale', {'pin': pin, 'order_id': id}))['order']));

  static Future<(List<StockItem>, List<StockMove>)> stock(String pin) async {
    final r = await _c('/soko/staff/stock', {'pin': pin});
    return (
      ((r['products'] as List?) ?? const []).map((e) => StockItem.fromJson(Map<String, dynamic>.from(e))).toList(),
      ((r['moves'] as List?) ?? const []).map((e) => StockMove.fromJson(Map<String, dynamic>.from(e))).toList(),
    );
  }

  // Dispatch orders: check out when the rider is at the shop, then send.
  static Future<DispatchCheckout> checkoutInfo(String pin, int orderId) async => DispatchCheckout.fromJson(
      Map<String, dynamic>.from((await _c('/soko/staff/dispatch/checkout_info', {'pin': pin, 'order_id': orderId}))['info']));

  static Future<Sale> dispatchCheckout(String pin,
      {required int orderId, required String uid, required List<Map<String, dynamic>> payments}) async {
    final r = await _c('/soko/staff/dispatch/checkout', {'pin': pin, 'order_id': orderId, 'uid': uid, 'payments': payments});
    return Sale.fromJson(Map<String, dynamic>.from(r['order']));
  }

  static Future<String> sendForDispatch(String pin, int orderId) async =>
      _s((await _c('/soko/staff/dispatch/send', {'pin': pin, 'order_id': orderId}))['message']);
}

class OnlinePayment {
  final int txnId;
  final String receipt;
  final double amount;
  final String phone;
  OnlinePayment.fromJson(Map<String, dynamic> j)
      : txnId = _i(j['txn_id']),
        receipt = _s(j['receipt']),
        amount = _d(j['amount']),
        phone = _s(j['phone']);
}

class DispatchCheckout {
  final int id;
  final String status;
  final String customer;
  final String phone;
  final bool checkedOut;
  final bool canCheckout;
  final bool canDispatch;
  final Sale? sale;
  final List<SaleLine> lines;
  final double total;
  final OnlinePayment? online;
  final String note;
  DispatchCheckout.fromJson(Map<String, dynamic> j)
      : id = _i(j['id']),
        status = _s(j['status']),
        customer = _s(j['customer']),
        phone = _s(j['phone']),
        checkedOut = j['checked_out'] == true,
        canCheckout = j['can_checkout'] == true,
        canDispatch = j['can_dispatch'] == true,
        sale = j['sale'] is Map ? Sale.fromJson(Map<String, dynamic>.from(j['sale'])) : null,
        lines = ((j['lines'] as List?) ?? const []).map((e) => SaleLine.fromJson(Map<String, dynamic>.from(e))).toList(),
        total = _d(j['total']),
        online = j['online'] is Map ? OnlinePayment.fromJson(Map<String, dynamic>.from(j['online'])) : null,
        note = _s(j['note']);
}
