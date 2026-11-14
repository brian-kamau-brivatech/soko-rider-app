import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class NetError implements Exception {
  final String message;
  final int status;
  final Map<String, dynamic> body;
  NetError(this.message, {this.status = 0, this.body = const {}});
  bool get offline => status == 0;
  @override
  String toString() => message;
}

/// JSON calls to the BRV server.
class Net {
  static Future<Map<String, dynamic>> call(String base, String method, String path,
      {Map<String, dynamic>? body, Map<String, String> headers = const {}, int timeoutSec = 25}) async {
    final uri = Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}/api$path');
    final h = {'Content-Type': 'application/json', ...headers};
    http.Response r;
    try {
      final f = switch (method) {
        'GET' => http.get(uri, headers: h),
        'DELETE' => http.delete(uri, headers: h),
        'PATCH' => http.patch(uri, headers: h, body: jsonEncode(body ?? {})),
        _ => http.post(uri, headers: h, body: jsonEncode(body ?? {})),
      };
      r = await f.timeout(Duration(seconds: timeoutSec));
    } on TimeoutException {
      throw NetError('No answer from the server (slow or no internet).');
    } catch (e) {
      throw NetError('No internet or the server cannot be reached.');
    }
    Map<String, dynamic> data = {};
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) data = Map<String, dynamic>.from(j);
    } catch (_) {}
    if (r.statusCode >= 400 || data['ok'] == false) {
      final msg = data['error'] ?? data['detail'] ?? 'Server error ${r.statusCode}';
      throw NetError('$msg', status: r.statusCode, body: data);
    }
    return data;
  }
}
