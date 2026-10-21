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
