import 'package:flutter/foundation.dart';
import 'config.dart';
import 'db.dart';
import 'fmt.dart';

/// Business settings, kept in the database (so they travel with a backup).
class Settings extends ChangeNotifier {
  Settings._();
  static final Settings i = Settings._();

  final Map<String, String> _v = {};

  Future<void> load() async {
    _v.clear();
    for (final r in await Db.q('SELECT k, v FROM kv')) {
      _v[s(r['k'])] = s(r['v']);
    }
    notifyListeners();
  }

  String get(String k, [String def = '']) => _v[k] ?? def;
  bool flag(String k, [bool def = false]) => _v.containsKey(k) ? _v[k] == '1' : def;
  double numVal(String k, [double def = 0]) => double.tryParse(_v[k] ?? '') ?? def;

  Future<void> set(String k, String v) async {
    _v[k] = v;
    await Db.setKv(k, v);
    notifyListeners();
  }

  Future<void> setFlag(String k, bool v) => set(k, v ? '1' : '0');

  bool get ready => get('business_name').isNotEmpty;
  String get businessName => get('business_name');
  String get address => get('address');
  String get phone => get('phone');
  String get email => get('email');
  String get taxPin => get('tax_pin');
  String get receiptHeader => get('receipt_header');
  String get receiptFooter => get('receipt_footer', 'Thank you for your business!');
  bool get vatRegistered => flag('vat_registered', true);
  bool get requireShift => isSalesApp || flag('require_shift', true); // sales devices always sell inside a session
  bool get blockNoStock => flag('block_no_stock', true);
  bool get printAfterSale => flag('print_after_sale', true);
  int get paperMm => numVal('paper_mm', 58).toInt();
  /// Minutes without a touch before the app locks (0 = never).
  int get lockMinutes => numVal('lock_minutes', 2).toInt();
}
