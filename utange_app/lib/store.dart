import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'config.dart';

/// Device settings and who is signed in.
///
/// Utange POS: server + device PIN + the chosen Point of Sale, then a cashier (POS employee + PIN).
/// Utange Manager: server + the manager's Odoo login.
class Store extends ChangeNotifier {
  Store._();
  static final Store i = Store._();
  late SharedPreferences _p;

  String server = '';
  String db = '';
  // POS
  String pin = '';
  int configId = 0;
  String configName = '';
  String companyName = '';
  int companyId = 0;
  bool cashiersOn = true;
  String cashierToken = '';
  String cashierName = '';
  String cashierRole = '';
  Uint8List? logo;
  // Manager
  String managerName = '';

  bool get posReady => server.isNotEmpty && pin.isNotEmpty && configId > 0;
  bool get managerReady => server.isNotEmpty && managerName.isNotEmpty && Api.cookie.isNotEmpty;
  bool get needsCashier => posReady && cashiersOn && cashierToken.isEmpty;
  bool get isManager => !cashiersOn || cashierRole == 'manager';

  Map<String, dynamic> base([Map<String, dynamic> extra = const {}]) => {
        'pin': pin,
        'config_id': configId,
        if (cashierToken.isNotEmpty) 'cashier': cashierToken,
        ...extra,
      };

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    server = _p.getString('server') ?? AppConfig.defaultServer;
    db = _p.getString('db') ?? AppConfig.defaultDb;
    pin = _p.getString('pin') ?? '';
    configId = _p.getInt('config_id') ?? 0;
    configName = _p.getString('config_name') ?? '';
    companyName = _p.getString('company') ?? '';
    companyId = _p.getInt('company_id') ?? 0;
    cashiersOn = _p.getBool('cashiers_on') ?? true;
    cashierToken = _p.getString('cashier_token') ?? '';
    cashierName = _p.getString('cashier_name') ?? '';
    cashierRole = _p.getString('cashier_role') ?? '';
    managerName = _p.getString('manager_name') ?? '';
    final logoB64 = _p.getString('logo');
    if (logoB64 != null && logoB64.isNotEmpty) {
      try {
        logo = _b64(logoB64);
      } catch (_) {}
    }
    Api.server = server;
    Api.db = db;
    Api.cookie = _p.getString('cookie') ?? '';
    Api.onCookie = (c) => _p.setString('cookie', c);
  }

  Uint8List _b64(String s) => Uint8List.fromList(const Base64Codec().decode(s));

  Future<void> setServer(String url, String database) async {
    var u = url.trim();
    if (u.isNotEmpty && !u.startsWith('http')) u = 'https://$u';
    u = u.replaceAll(RegExp(r'/+$'), '');
    if (u != server || database.trim() != db) {
      Api.cookie = '';
      await _p.remove('cookie');
    }
    server = u;
    db = database.trim();
    Api.server = server;
    Api.db = db;
    await _p.setString('server', server);
    await _p.setString('db', db);
    await Api.selectDb();
  }

  // ---------------------------------------------------------------- POS
  /// Checks the device PIN and returns the Points of Sale.
  String _pendingToken = '';

  Future<(String, List<PosConfigInfo>)> checkDevice(String devicePin) async {
    final r = await Api.call('/utange/pos/configs', {'pin': devicePin});
    _pendingToken = ss(r['token']);
    final company = Map<String, dynamic>.from(r['company'] as Map? ?? const {});
    companyName = ss(company['name']);
    companyId = ii(company['id']);
    return (companyName, ll(r['configs']).map(PosConfigInfo.fromJson).toList());
  }

  Future<void> saveDevice(String devicePin, PosConfigInfo c) async {
    pin = _pendingToken.isNotEmpty ? _pendingToken : devicePin;
    configId = c.id;
    configName = c.name;
    cashiersOn = c.cashiersOn;
    await _p.setString('pin', pin);
    await _p.setInt('config_id', configId);
    await _p.setString('config_name', configName);
    await _p.setString('company', companyName);
    await _p.setInt('company_id', companyId);
    await _p.setBool('cashiers_on', cashiersOn);
    await clearCashier();
    await loadLogo();
    notifyListeners();
  }

  Future<void> loadLogo() async {
    try {
      final r = await http.get(Uri.parse(Api.url('/logo.png?company=${companyId > 0 ? companyId : 1}')),
          headers: {if (Api.cookie.isNotEmpty) 'Cookie': 'session_id=${Api.cookie}'}).timeout(const Duration(seconds: 20));
      if (r.statusCode == 200 && r.bodyBytes.length > 100) {
        logo = r.bodyBytes;
        await _p.setString('logo', const Base64Codec().encode(r.bodyBytes));
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> forgetDevice() async {
    pin = '';
    configId = 0;
    await _p.remove('pin');
    await _p.remove('config_id');
    await clearCashier();
    notifyListeners();
  }

  Future<void> setCashier(String token, String name, String role) async {
    cashierToken = token;
    cashierName = name;
    cashierRole = role;
    await _p.setString('cashier_token', token);
    await _p.setString('cashier_name', name);
    await _p.setString('cashier_role', role);
    notifyListeners();
  }

  Future<void> clearCashier() async {
    cashierToken = '';
    cashierName = '';
    cashierRole = '';
    await _p.remove('cashier_token');
    await _p.remove('cashier_name');
    await _p.remove('cashier_role');
    notifyListeners();
  }

  Future<void> setCashiersOn(bool on) async {
    cashiersOn = on;
    await _p.setBool('cashiers_on', on);
    if (!on) await clearCashier();
    notifyListeners();
  }

  /// Handles an API error: device PIN wrong -> setup again; cashier needed -> sign-in screen.
  Future<void> handle(ApiError e) async {
    if (e.device) await forgetDevice();
    if (e.cashier) await clearCashier();
    if (e.login) await managerSignOut();
  }

  // ---------------------------------------------------------------- Manager
  Future<void> managerSignIn(String login, String password) async {
    final r = await Api.call('/web/session/authenticate', {'db': db, 'login': login.trim(), 'password': password});
    if (r['uid'] == null || r['uid'] == false) throw ApiError('Wrong username or password.');
    final me = await Api.call('/utange/mgr/me', {});
    managerName = ss(me['name']);
    companyName = ss(me['company']);
    await _p.setString('manager_name', managerName);
    await _p.setString('company', companyName);
    notifyListeners();
  }

  Future<void> managerSignOut() async {
    try {
      await Api.call('/web/session/destroy', {});
    } catch (_) {}
    managerName = '';
    Api.cookie = '';
    await _p.remove('manager_name');
    await _p.remove('cookie');
    notifyListeners();
  }
}
