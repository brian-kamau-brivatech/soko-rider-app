import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';

/// App-wide state: catalogue, cart, saved customer details and order list.
/// Everything personal stays on the phone (no account needed).
class AppStore extends ChangeNotifier {
  AppStore._();
  static final AppStore instance = AppStore._();

  Catalog? catalog;
  String? catalogError;
  bool loading = false;

  /// product id -> quantity
  final Map<int, double> cart = {};

  // Saved checkout details
  String name = '';
  String phone = '';
  String street = '';
  String street2 = '';
  double? lat;
  double? lng;

  /// Signed-in account (empty = guest).
  String session = '';
  bool authSeen = false;
  bool get signedIn => session.isNotEmpty;

  /// Orders placed from this phone: [{id, token}]
  List<Map<String, dynamic>> orderRefs = [];

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    name = _prefs.getString('c_name') ?? '';
    phone = _prefs.getString('c_phone') ?? '';
    street = _prefs.getString('c_street') ?? '';
    street2 = _prefs.getString('c_street2') ?? '';
    lat = _prefs.getDouble('c_lat');
    lng = _prefs.getDouble('c_lng');
    session = _prefs.getString('session') ?? '';
    authSeen = _prefs.getBool('auth_seen') ?? false;
    try {
      final c = jsonDecode(_prefs.getString('cart') ?? '{}') as Map;
      c.forEach((k, v) => cart[int.parse('$k')] = (v as num).toDouble());
    } catch (_) {}
    try {
      orderRefs = (jsonDecode(_prefs.getString('orders') ?? '[]') as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {}
  }

  Future<void> loadCatalog({bool force = false}) async {
    if (loading || (catalog != null && !force)) return;
    loading = true;
    catalogError = null;
    notifyListeners();
    try {
      catalog = await ShopApi.catalog();
      // Drop cart items that are no longer sold.
      final ids = catalog!.products.map((p) => p.id).toSet();
      cart.removeWhere((k, _) => !ids.contains(k));
    } catch (e) {
      catalogError = '$e';
    }
    loading = false;
    notifyListeners();
  }

  Product? product(int id) {
    for (final p in catalog?.products ?? const <Product>[]) {
      if (p.id == id) return p;
    }
    return null;
  }

  double qty(int id) => cart[id] ?? 0;

  void setQty(int id, double q) {
    if (q <= 0) {
      cart.remove(id);
    } else {
      cart[id] = q;
    }
    _saveCart();
    notifyListeners();
  }

  void add(int id) => setQty(id, qty(id) + 1);
  void remove(int id) => setQty(id, qty(id) - 1);

  void clearCart() {
    cart.clear();
    _saveCart();
    notifyListeners();
  }

  int get cartCount => cart.values.fold(0, (a, q) => a + q.round());

  double get cartTotal {
    double t = 0;
    cart.forEach((id, q) => t += (product(id)?.price ?? 0) * q);
    return t;
  }

  void _saveCart() {
    _prefs.setString('cart', jsonEncode(cart.map((k, v) => MapEntry('$k', v))));
  }

  Future<void> saveDetails({
    required String name,
    required String phone,
    required String street,
    required String street2,
    required double lat,
    required double lng,
  }) async {
    this.name = name;
    this.phone = phone;
    this.street = street;
    this.street2 = street2;
    this.lat = lat;
    this.lng = lng;
    await _prefs.setString('c_name', name);
    await _prefs.setString('c_phone', phone);
    await _prefs.setString('c_street', street);
    await _prefs.setString('c_street2', street2);
    await _prefs.setDouble('c_lat', lat);
    await _prefs.setDouble('c_lng', lng);
  }

  /// Save a signed-in session and the profile the server sent back.
  Future<void> signedInWith(Map<String, dynamic> r) async {
    session = '${r['session'] ?? ''}';
    await _prefs.setString('session', session);
    await markAuthSeen();
    applyProfile(r['profile']);
  }

  void applyProfile(dynamic p) {
    if (p is! Map) return;
    String s(String k) => (p[k] == null || p[k] == false) ? '' : '${p[k]}';
    if (s('name').isNotEmpty) name = s('name');
    if (s('phone').isNotEmpty) phone = s('phone');
    if (s('street').isNotEmpty) street = s('street');
    if (s('street2').isNotEmpty) street2 = s('street2');
    if (p['lat'] is num && p['lng'] is num) {
      lat = (p['lat'] as num).toDouble();
      lng = (p['lng'] as num).toDouble();
      _prefs.setDouble('c_lat', lat!);
      _prefs.setDouble('c_lng', lng!);
    }
    _prefs.setString('c_name', name);
    _prefs.setString('c_phone', phone);
    _prefs.setString('c_street', street);
    _prefs.setString('c_street2', street2);
    notifyListeners();
  }

  Future<void> markAuthSeen() async {
    authSeen = true;
    await _prefs.setBool('auth_seen', true);
    notifyListeners();
  }

  Future<void> signOut() async {
    session = '';
    await _prefs.remove('session');
    notifyListeners();
  }

  /// Refresh the profile in the background (also drops an expired session).
  Future<void> refreshProfile() async {
    if (!signedIn) return;
    try {
      final r = await ShopApi.me(session);
      applyProfile(r['profile']);
    } on ApiError catch (e) {
      if (e.message.contains('sign in')) await signOut();
    } catch (_) {}
  }

  Future<void> rememberOrder(ShopOrder o) async {
    orderRefs.removeWhere((e) => e['id'] == o.id);
    orderRefs.insert(0, {'id': o.id, 'token': o.token});
    if (orderRefs.length > 50) orderRefs = orderRefs.sublist(0, 50);
    await _prefs.setString('orders', jsonEncode(orderRefs));
    notifyListeners();
  }
}
