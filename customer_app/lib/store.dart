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

  Future<void> rememberOrder(ShopOrder o) async {
    orderRefs.removeWhere((e) => e['id'] == o.id);
    orderRefs.insert(0, {'id': o.id, 'token': o.token});
    if (orderRefs.length > 50) orderRefs = orderRefs.sublist(0, 50);
    await _prefs.setString('orders', jsonEncode(orderRefs));
    notifyListeners();
  }
}
