import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class NetError implements Exception {
  final String message;
  final int status;
  final bool offline;
  NetError(this.message, {this.status = 0, this.offline = false});
  @override
  String toString() => message;
}

/// Talks to the Coast Bus Odoo (courier module API).
class Api {
  /// Built into the APK (GitHub variable COURIER_SERVER); never shown, typed or stored on the terminal.
  static const String server = String.fromEnvironment('COURIER_SERVER', defaultValue: 'https://coastbus.brvsystems.co.ke');
  static String token = '';

  static String base(String srv) {
    var s = srv.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static Future<Map<String, dynamic>> call(String method, String path,
      {Map<String, dynamic>? body, Map<String, String>? query, bool auth = true, int timeoutSec = 30}) async {
    final b = base(server);
    var uri = Uri.parse('$b/courier/api/v1$path');
    if (query != null) uri = uri.replace(queryParameters: query);
    final headers = {'Content-Type': 'application/json', if (token.isNotEmpty && auth) 'Authorization': 'Bearer $token'};
    http.Response r;
    try {
      final f = method == 'GET' ? http.get(uri, headers: headers) : http.post(uri, headers: headers, body: jsonEncode(body ?? {}));
      r = await f.timeout(Duration(seconds: timeoutSec));
    } on TimeoutException {
      throw NetError('No response from the server (slow or no network).', offline: true);
    } on SocketException {
      throw NetError('No network. Working offline.', offline: true);
    } on HandshakeException {
      throw NetError('Secure connection failed. Check the date and time on this terminal.', offline: true);
    } on http.ClientException catch (e) {
      throw NetError('Network problem: ${e.message}', offline: true);
    } on FormatException {
      throw NetError('Connection problem. Contact BRV Integrated Systems.');
    }
    Map<String, dynamic> j;
    try {
      j = Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bodyBytes)) as Map);
    } catch (_) {
      if (r.statusCode == 404) throw NetError('The courier service is not available right now. Contact BRV Integrated Systems.', status: 404);
      throw NetError('Unexpected answer from the server (${r.statusCode}).', status: r.statusCode);
    }
    if (r.statusCode >= 400 || j['ok'] == false) {
      throw NetError('${j['error'] ?? 'Server error ${r.statusCode}'}', status: r.statusCode);
    }
    return j;
  }
}
