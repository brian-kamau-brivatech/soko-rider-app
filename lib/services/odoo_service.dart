import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/delivery_order.dart';

class OdooService {
  String baseUrl;
  String db;
  String? _sessionCookie;
  int? _uid;

  OdooService({required this.baseUrl, required this.db});

  /// 1. Authenticate Rider with Odoo ERP (Free native JSON-RPC)
  Future<bool> login(String login, String password) async {
    final uri = Uri.parse('$baseUrl/web/session/authenticate');
    try {
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'params': {
            'db': db,
            'login': login,
            'password': password,
          }
        }),
      );

      final data = jsonDecode(response.body);
      if (data['result'] != null && data['result']['uid'] != null) {
        _uid = data['result']['uid'];
        _sessionCookie = response.headers['set-cookie'];

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('cookie', _sessionCookie ?? '');
        await prefs.setInt('uid', _uid ?? 0);
        await prefs.setString('baseUrl', baseUrl);
        await prefs.setString('db', db);
        return true;
      }
    } catch (e) {
      print('Odoo Login Error: $e');
    }
    return false;
  }

  /// 2. Fetch assigned deliveries for this rider
  Future<List<DeliveryOrder>> getAssignedDeliveries() async {
    final uri = Uri.parse('$baseUrl/web/dataset/call_kw');
    try {
      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          if (_sessionCookie != null) 'Cookie': _sessionCookie!,
        },
        body: jsonEncode({
          'jsonrpc': '2.0',
          'params': {
            'model': 'stock.picking',
            'method': 'search_read',
            'args': [
              [
                ['state', 'in', ['assigned', 'confirmed']]
              ]
            ],
            'kwargs': {
              'fields': [
                'id',
                'name',
                'partner_id',
                'tracking_token',
                'delivery_latitude',
                'delivery_longitude',
                'state'
              ],
              'limit': 20,
            }
          }
        }),
      );

      final data = jsonDecode(response.body);
      if (data['result'] != null) {
        final List results = data['result'];
        return results.map((item) => DeliveryOrder.fromOdooJson(item)).toList();
      }
    } catch (e) {
      print('Fetch Deliveries Error: $e');
    }
    return [];
  }

  /// 3. Mark delivery as done in Odoo (Validates picking)
  Future<bool> markOrderDelivered(int pickingId) async {
    final uri = Uri.parse('$baseUrl/web/dataset/call_kw');
    try {
      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          if (_sessionCookie != null) 'Cookie': _sessionCookie!,
        },
        body: jsonEncode({
          'jsonrpc': '2.0',
          'params': {
            'model': 'stock.picking',
            'method': 'button_validate',
            'args': [
              [pickingId]
            ],
            'kwargs': {}
          }
        }),
      );

      final data = jsonDecode(response.body);
      return data['result'] != null;
    } catch (e) {
      print('Mark Delivered Error: $e');
    }
    return false;
  }
}
