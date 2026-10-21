import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

double _d(dynamic v) => v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);
int _i(dynamic v) => v is int ? v : (int.tryParse('$v') ?? 0);
String _s(dynamic v) => (v == null || v == false) ? '' : '$v';

String absUrl(String path) {
  if (path.isEmpty || path.startsWith('http')) return path;
  return '${AppConfig.baseUrl}$path';
}

class Product {
  final int id;
  final String name;
  final double price;
  final String uom;
  final String description;
  final List<int> categIds;
  final String image;
  final String thumb;
  Product.fromJson(Map<String, dynamic> j)
      : id = _i(j['id']),
        name = _s(j['name']),
        price = _d(j['price']),
        uom = _s(j['uom']),
        description = _s(j['description']),
        categIds = ((j['categ_ids'] as List?) ?? const []).map(_i).toList(),
        image = absUrl(_s(j['image'])),
        thumb = absUrl(_s(j['thumb']));
}

class Category {
  final int id;
  final String name;
  final String image;
  Category.fromJson(Map<String, dynamic> j)
      : id = _i(j['id']),
        name = _s(j['name']),
        image = absUrl(_s(j['image']));
}

class Catalog {
  final List<Product> products;
  final List<Category> categories;
  final double shopLat;
  final double shopLng;
  final String banner;
  Catalog.fromJson(Map<String, dynamic> j)
      : products = ((j['products'] as List?) ?? const [])
            .map((e) => Product.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        categories = ((j['categories'] as List?) ?? const [])
            .map((e) => Category.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        shopLat = _d((j['shop'] ?? const {})['lat']),
        shopLng = _d((j['shop'] ?? const {})['lng']),
        banner = absUrl(_s(j['banner']));
}

class Quote {
  final bool ok;
  final double km;
  final double fee;
  final String error;
  Quote.fromJson(Map<String, dynamic> j)
      : ok = j['ok'] == true,
        km = _d(j['km']),
        fee = _d(j['fee']),
        error = _s(j['error']);
}

class OrderLine {
  final String name;
  final double qty;
  final double total;
  final String thumb;
  OrderLine.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        qty = _d(j['qty']),
        total = _d(j['total']),
        thumb = absUrl(_s(j['thumb']));
}

class ShopOrder {
  final int id;
  final String name;
  final String token;
  final String state;
  final bool paid;
  final String mpesaState;
  final double amountTotal;
  final double deliveryFee;
  final String date;
  final String phone;
  final List<OrderLine> lines;
  final double? destLat;
  final double? destLng;
  // Dispatch
  final String status;
  final String trackingNo;
  final String riderName;
  final String riderPhone;
  final double? riderLat;
  final double? riderLng;

  ShopOrder.fromJson(Map<String, dynamic> j)
      : id = _i(j['id']),
        name = _s(j['name']),
        token = _s(j['token']),
        state = _s(j['state']),
        paid = j['paid'] == true,
        mpesaState = _s(j['mpesa_state']),
        amountTotal = _d(j['amount_total']),
        deliveryFee = _d(j['delivery_fee']),
        date = _s(j['date']),
        phone = _s(j['phone']),
        lines = ((j['lines'] as List?) ?? const [])
            .map((e) => OrderLine.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        destLat = (j['dest'] is Map && _d(j['dest']['lat']) != 0) ? _d(j['dest']['lat']) : null,
        destLng = (j['dest'] is Map && _d(j['dest']['lng']) != 0) ? _d(j['dest']['lng']) : null,
        status = j['dispatch'] is Map ? _s(j['dispatch']['status']) : '',
        trackingNo = j['dispatch'] is Map ? _s(j['dispatch']['tracking_no']) : '',
        riderName = j['dispatch'] is Map ? _s(j['dispatch']['rider_name']) : '',
        riderPhone = j['dispatch'] is Map ? _s(j['dispatch']['rider_phone']) : '',
        riderLat = (j['dispatch'] is Map && j['dispatch']['rider'] is Map) ? _d(j['dispatch']['rider']['lat']) : null,
        riderLng = (j['dispatch'] is Map && j['dispatch']['rider'] is Map) ? _d(j['dispatch']['rider']['lng']) : null;

  int get itemCount => lines.fold(0, (a, l) => a + l.qty.round());
  bool get cancelled => state == 'cancel';
  bool get delivered => status == 'delivered' || status == 'done';

  /// 0 = waiting for payment, 1 paid, 2 rider/packing, 3 on the way, 4 delivered.
  int get step {
    if (delivered) return 4;
    if (status == 'out_for_delivery') return 3;
    if (riderName.isNotEmpty || status == 'preparing') return 2;
    if (paid || state == 'sale' || state == 'done') return 1;
    return 0;
  }

  String get statusLabel {
    if (cancelled) return 'Cancelled';
    switch (step) {
      case 4:
        return 'Delivered';
      case 3:
        return 'On the way';
      case 2:
        return status == 'preparing' ? 'Packing your order' : 'Rider assigned';
      case 1:
        return 'Paid · preparing';
      default:
        return 'Waiting for payment';
    }
  }
}

class ApiError implements Exception {
  final String message;
  ApiError(this.message);
  @override
  String toString() => message;
}

class ShopApi {
  static const _timeout = Duration(seconds: 25);

  static Future<Map<String, dynamic>> _call(String path, Map<String, dynamic> params) async {
    http.Response r;
    try {
      r = await http
          .post(Uri.parse('${AppConfig.baseUrl}$path'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'jsonrpc': '2.0', 'method': 'call', 'params': params}))
          .timeout(_timeout);
    } on TimeoutException {
      throw ApiError('The shop did not respond. Check your internet.');
    } catch (_) {
      throw ApiError('No internet connection.');
    }
    if (r.statusCode != 200) throw ApiError('Shop server error (${r.statusCode}).');
    final data = jsonDecode(r.body);
    if (data is Map && data['error'] != null) {
      final e = data['error'];
      final msg = e is Map ? ((e['data'] is Map ? e['data']['message'] : null) ?? e['message']) : '$e';
      throw ApiError('$msg');
    }
    return Map<String, dynamic>.from((data as Map)['result'] ?? const {});
  }

  static Future<Map<String, dynamic>> _auth(String path, Map<String, dynamic> params) async {
    final r = await _call(path, params);
    if (r['ok'] != true) throw ApiError(_s(r['error']).isEmpty ? 'Something went wrong.' : _s(r['error']));
    return r;
  }

  static Future<Map<String, dynamic>> signUp(String name, String phone, String pin) =>
      _auth('/soko/shop/signup', {'name': name, 'phone': phone, 'pin': pin});

  static Future<Map<String, dynamic>> signIn(String phone, String pin) =>
      _auth('/soko/shop/signin', {'phone': phone, 'pin': pin});

  static Future<Map<String, dynamic>> me(String session) => _auth('/soko/shop/me', {'session': session});

  static Future<Catalog> catalog() async => Catalog.fromJson(await _call('/soko/shop/catalog', {}));

  static Future<Quote> quote(double lat, double lng) async =>
      Quote.fromJson(await _call('/soko/shop/quote', {'lat': lat, 'lng': lng}));

  static Future<ShopOrder> createOrder({
    required String name,
    required String phone,
    required String street,
    required String street2,
    required double lat,
    required double lng,
    required Map<int, double> lines,
    String note = '',
    String session = '',
  }) async {
    final r = await _call('/soko/shop/order', {
      'session': session,
      'name': name,
      'phone': phone,
      'street': street,
      'street2': street2,
      'lat': lat,
      'lng': lng,
      'note': note,
      'lines': lines.entries.map((e) => {'product_id': e.key, 'qty': e.value}).toList(),
    });
    if (r['ok'] != true) throw ApiError(_s(r['error']).isEmpty ? 'Could not place the order.' : _s(r['error']));
    return ShopOrder.fromJson(Map<String, dynamic>.from(r['order']));
  }

  /// Ask the server to send the M-Pesa prompt to [phone] for this order.
  static Future<String> pay(int orderId, String token, String phone) async {
    final r = await _call('/soko/shop/pay', {'order_id': orderId, 'token': token, 'phone': phone});
    if (r['ok'] != true) throw ApiError(_s(r['error']).isEmpty ? 'Could not send the M-Pesa prompt.' : _s(r['error']));
    return _s(r['message']);
  }

  /// [check] = also ask Safaricom right now (used by "I've paid · check now").
  static Future<ShopOrder> status(int orderId, String token, {bool check = false}) async {
    final r = await _call('/soko/shop/status', {'order_id': orderId, 'token': token, 'check': check});
    if (r['ok'] != true) throw ApiError(_s(r['error']));
    return ShopOrder.fromJson(Map<String, dynamic>.from(r['order']));
  }

  static Future<List<ShopOrder>> orders(List<Map<String, dynamic>> items, {String session = ''}) async {
    final r = await _call('/soko/shop/orders', {'items': items, 'session': session});
    return ((r['orders'] as List?) ?? const [])
        .map((e) => ShopOrder.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}
