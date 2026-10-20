import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../models/delivery_order.dart';

class OdooService {
  final String baseUrl;

  OdooService({String? baseUrl}) : baseUrl = baseUrl ?? AppConfig.odooBaseUrl;

  /// 1. Check Rider Phone Registration & Approval Status
  Future<Map<String, dynamic>> checkStatus(String phone) async {
    final uri = Uri.parse('$baseUrl/api/rider/check_status');
    try {
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'params': {'phone': phone.trim()}
        }),
      );

      final data = jsonDecode(response.body);
      if (data['result'] != null) {
        return Map<String, dynamic>.from(data['result']);
      }
    } catch (e) {
      print('Check Status Error: $e');
    }
    return {'status': 'error', 'message': 'Network error reaching Soko Server.'};
  }

  /// 2. Rider First-Time PIN Creation
  Future<Map<String, dynamic>> createPin(String phone, String pin) async {
    final uri = Uri.parse('$baseUrl/api/rider/create_pin');
    try {
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'params': {'phone': phone.trim(), 'pin': pin.trim()}
        }),
      );

      final data = jsonDecode(response.body);
      if (data['result'] != null) {
        return Map<String, dynamic>.from(data['result']);
      }
    } catch (e) {
      print('Create PIN Error: $e');
    }
    return {'success': false, 'message': 'Network error setting PIN.'};
  }

  /// 3. Rider Phone + PIN Login
  Future<bool> login(String phone, String pin) async {
    final uri = Uri.parse('$baseUrl/api/rider/login');
    try {
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'params': {'phone': phone.trim(), 'pin': pin.trim()}
        }),
      );

      final data = jsonDecode(response.body);
      if (data['result'] != null && data['result']['success'] == true) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('rider_phone', phone.trim());
        await prefs.setString('rider_pin', pin.trim());
        await prefs.setString('rider_name', data['result']['name'] ?? 'Rider');
        await prefs.setInt('rider_id', data['result']['rider_id'] ?? 0);
        return true;
      }
    } catch (e) {
      print('Rider Login Error: $e');
    }
    return false;
  }

  /// 4. Fetch assigned active delivery orders
  Future<List<DeliveryOrder>> getAssignedDeliveries() async {
    final prefs = await SharedPreferences.getInstance();
    final phone = prefs.getString('rider_phone') ?? '';
    final pin = prefs.getString('rider_pin') ?? '';

    final uri = Uri.parse('$baseUrl/api/rider/assigned_orders');
    try {
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'params': {'phone': phone, 'pin': pin}
        }),
      );

      final data = jsonDecode(response.body);
      if (data['result'] != null && data['result']['success'] == true) {
        final List ordersJson = data['result']['orders'] ?? [];
        return ordersJson.map((item) => DeliveryOrder.fromOdooJson(item)).toList();
      }
    } catch (e) {
      print('Fetch Assigned Orders Error: $e');
    }
    return [];
  }

  /// 5. Mark delivery completed in Odoo
  Future<bool> markOrderDelivered(String trackingNo) async {
    final prefs = await SharedPreferences.getInstance();
    final phone = prefs.getString('rider_phone') ?? '';
    final pin = prefs.getString('rider_pin') ?? '';

    final uri = Uri.parse('$baseUrl/api/rider/update_status');
    try {
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'params': {
            'phone': phone,
            'pin': pin,
            'tracking_no': trackingNo,
            'status': 'delivered'
          }
        }),
      );

      final data = jsonDecode(response.body);
      return data['result'] != null && data['result']['success'] == true;
    } catch (e) {
      print('Mark Delivered Error: $e');
    }
    return false;
  }
}
