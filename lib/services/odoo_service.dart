import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../models/delivery_order.dart';

/// Result of loading the rider's orders. When [error] is set the list could
/// not be loaded, which is different from "no orders assigned".
class OrdersResult {
  final List<DeliveryOrder> orders;
  final String? error;
  /// True when the server does not have this endpoint yet (HTTP 404).
  final bool notAvailable;
  const OrdersResult(this.orders, [this.error, this.notAvailable = false]);
  bool get ok => error == null;
}

/// Saved rider profile (from check_status + login).
class RiderProfile {
  final String phone;
  final String name;
  final int riderId;
  final String vehicleType;
  final String vehicleRegNo;
  const RiderProfile({
    required this.phone,
    required this.name,
    required this.riderId,
    required this.vehicleType,
    required this.vehicleRegNo,
  });
}

class OdooService {
  final String baseUrl;
  static const _timeout = Duration(seconds: 20);

  OdooService({String? baseUrl}) : baseUrl = baseUrl ?? AppConfig.odooBaseUrl;

  /// POST a JSON-RPC call to an Odoo `type='json'` route.
  /// Returns the `result` map, or throws [OdooCallError] with a readable message.
  Future<Map<String, dynamic>> _call(String path, Map<String, dynamic> params) async {
    final uri = Uri.parse('$baseUrl$path');
    http.Response response;
    try {
      response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'jsonrpc': '2.0', 'method': 'call', 'params': params}),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw OdooCallError('Soko server did not respond. Check your internet.');
    } catch (_) {
      throw OdooCallError('No internet connection to Soko server.');
    }

    if (response.statusCode == 404) {
      throw OdooCallError('Server endpoint $path is missing (404). Contact Soko admin.', 404);
    }
    if (response.statusCode != 200) {
      throw OdooCallError('Soko server error (HTTP ${response.statusCode}).');
    }

    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      throw OdooCallError('Unexpected reply from Soko server.');
    }

    if (data is Map && data['error'] != null) {
      final err = data['error'];
      final msg = (err is Map)
          ? ((err['data'] is Map ? err['data']['message'] : null) ?? err['message'])
          : err.toString();
      throw OdooCallError('Server error: $msg');
    }
    if (data is Map && data['result'] is Map) {
      return Map<String, dynamic>.from(data['result']);
    }
    throw OdooCallError('Empty reply from Soko server.');
  }

  /// 1. Check Rider Phone Registration & Approval Status
  Future<Map<String, dynamic>> checkStatus(String phone) async {
    try {
      final res = await _call('/api/rider/check_status', {'phone': phone.trim()});
      if (res['status'] == 'ready') {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('vehicle_type', _s(res['vehicle_type']));
        await prefs.setString('vehicle_reg_no', _s(res['vehicle_reg_no']));
      }
      return res;
    } on OdooCallError catch (e) {
      return {'status': 'error', 'message': e.message};
    }
  }

  /// 2. Rider First-Time PIN Creation
  Future<Map<String, dynamic>> createPin(String phone, String pin) async {
    try {
      return await _call('/api/rider/create_pin', {'phone': phone.trim(), 'pin': pin.trim()});
    } on OdooCallError catch (e) {
      return {'success': false, 'message': e.message};
    }
  }

  /// 3. Rider Phone + PIN Login. Returns null on success, or an error message.
  Future<String?> login(String phone, String pin) async {
    try {
      final res = await _call('/api/rider/login', {'phone': phone.trim(), 'pin': pin.trim()});
      if (res['success'] == true) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('rider_phone', phone.trim());
        await prefs.setString('rider_pin', pin.trim());
        await prefs.setString('rider_name', _s(res['name']).isEmpty ? 'Rider' : _s(res['name']));
        await prefs.setInt('rider_id', (res['rider_id'] is int) ? res['rider_id'] as int : 0);
        return null;
      }
      return _s(res['message']).isEmpty ? 'Invalid PIN. Please try again.' : _s(res['message']);
    } on OdooCallError catch (e) {
      return e.message;
    }
  }

  /// Saved session, or null if the rider has not logged in on this phone.
  Future<RiderProfile?> getSavedProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final phone = prefs.getString('rider_phone') ?? '';
    final pin = prefs.getString('rider_pin') ?? '';
    if (phone.isEmpty || pin.isEmpty) return null;
    return RiderProfile(
      phone: phone,
      name: prefs.getString('rider_name') ?? 'Rider',
      riderId: prefs.getInt('rider_id') ?? 0,
      vehicleType: prefs.getString('vehicle_type') ?? '',
      vehicleRegNo: prefs.getString('vehicle_reg_no') ?? '',
    );
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in ['rider_phone', 'rider_pin', 'rider_name', 'rider_id', 'vehicle_type', 'vehicle_reg_no', 'seen_order_ids']) {
      await prefs.remove(k);
    }
  }

  Future<Map<String, String>> _creds() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'phone': prefs.getString('rider_phone') ?? '',
      'pin': prefs.getString('rider_pin') ?? '',
    };
  }

  /// 4. Fetch assigned active delivery orders (with a real error if it fails)
  Future<OrdersResult> getAssignedDeliveries() async {
    try {
      final res = await _call('/api/rider/assigned_orders', await _creds());
      if (res['success'] != true) {
        return OrdersResult(const [], _s(res['message']).isEmpty ? 'Server refused the request.' : _s(res['message']));
      }
      final List ordersJson = (res['orders'] is List) ? res['orders'] as List : const [];
      final orders = ordersJson
          .whereType<Map>()
          .map((item) => DeliveryOrder.fromOdooJson(Map<String, dynamic>.from(item)))
          .toList();
      return OrdersResult(orders);
    } on OdooCallError catch (e) {
      return OrdersResult(const [], e.message);
    }
  }

  /// Completed deliveries for "Recent Dispatches".
  /// Needs `/api/rider/history` on the server; until it exists the app hides the list.
  Future<OrdersResult> getRecentDeliveries({int limit = 10}) async {
    try {
      final res = await _call('/api/rider/history', {...await _creds(), 'limit': limit});
      if (res['success'] != true) {
        return OrdersResult(const [], _s(res['message']).isEmpty ? 'Could not load history.' : _s(res['message']));
      }
      final List list = (res['orders'] is List) ? res['orders'] as List : const [];
      return OrdersResult(list
          .whereType<Map>()
          .map((item) => DeliveryOrder.fromOdooJson(Map<String, dynamic>.from(item)))
          .toList());
    } on OdooCallError catch (e) {
      return OrdersResult(const [], e.message, e.statusCode == 404);
    }
  }

  /// Order ids the rider has already seen (for the bell's "new order" dot).
  Future<Set<int>> getSeenOrderIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('seen_order_ids') ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
  }

  Future<void> markOrdersSeen(Iterable<int> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('seen_order_ids', ids.map((e) => '$e').toList());
  }

  /// 5. Mark delivery completed in Odoo. Returns null on success, or an error message.
  Future<String?> markOrderDelivered(String trackingNo) async {
    try {
      final res = await _call('/api/rider/update_status', {
        ...await _creds(),
        'tracking_no': trackingNo,
        'status': 'delivered',
      });
      if (res['success'] == true) return null;
      return _s(res['message']).isEmpty ? 'Odoo did not accept the update.' : _s(res['message']);
    } on OdooCallError catch (e) {
      return e.message;
    }
  }

  static String _s(dynamic v) => (v == null || v == false) ? '' : v.toString();
}

class OdooCallError implements Exception {
  final String message;
  final int? statusCode;
  OdooCallError(this.message, [this.statusCode]);
  @override
  String toString() => message;
}
