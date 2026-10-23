import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Everything entered in Settings, plus what KRA returned at initialisation.
class Settings extends ChangeNotifier {
  Settings._();
  static final Settings i = Settings._();
  late SharedPreferences _p;

  // VSCU connection and device
  String vscuUrl = '';
  bool testMode = false;
  String tin = '';
  String bhfId = '00';
  String serial = '';

  // From KRA (selectInitInfo)
  bool initialised = false;
  String taxpayerName = '';
  String branchName = '';
  String location = '';
  String deviceId = '';
  String controlUnitId = ''; // sdcId (also comes with every signed sale)
  String mrcNo = '';
  String initAt = '';
  int? lastSaleInvcNo;

  // On the receipt
  String businessName = '';
  String address = '';
  String phone = '';
  String email = '';
  String header = '';
  String footer = 'Thank you for shopping with us!';
  String logoPath = '';
  int paperMm = 58;

  // Advanced
  bool taxableInclVat = false; // taxblAmt incl. VAT (KRA sample) vs excl. (Odoo/VSCU default)
  String cashier = '';

  bool get ready => initialised && vscuUrl.isNotEmpty && tin.isNotEmpty;
  String get shopName => businessName.isNotEmpty ? businessName : (taxpayerName.isNotEmpty ? taxpayerName : 'BRV POS');
  String get root => vscuUrl.trim().replaceAll(RegExp(r'/+$'), '');
  String get salesEndpoint => '$root/trnsSales/saveSales';

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    String s(String k, [String d = '']) => _p.getString(k) ?? d;
    vscuUrl = s('vscuUrl');
    testMode = _p.getBool('testMode') ?? false;
    tin = s('tin');
    bhfId = s('bhfId', '00');
    serial = s('serial');
    initialised = _p.getBool('initialised') ?? false;
    taxpayerName = s('taxpayerName');
    branchName = s('branchName');
    location = s('location');
    deviceId = s('deviceId');
    controlUnitId = s('controlUnitId');
    mrcNo = s('mrcNo');
    initAt = s('initAt');
    lastSaleInvcNo = _p.getInt('lastSaleInvcNo');
    businessName = s('businessName');
    address = s('address');
    phone = s('phone');
    email = s('email');
    header = s('header');
    footer = s('footer', 'Thank you for shopping with us!');
    logoPath = s('logoPath');
    paperMm = _p.getInt('paperMm') ?? 58;
    taxableInclVat = _p.getBool('taxableInclVat') ?? false;
    cashier = s('cashier');
  }

  Future<void> save() async {
    await _p.setString('vscuUrl', vscuUrl.trim());
    await _p.setBool('testMode', testMode);
    await _p.setString('tin', tin);
    await _p.setString('bhfId', bhfId);
    await _p.setString('serial', serial);
    await _p.setBool('initialised', initialised);
    await _p.setString('taxpayerName', taxpayerName);
    await _p.setString('branchName', branchName);
    await _p.setString('location', location);
    await _p.setString('deviceId', deviceId);
    await _p.setString('controlUnitId', controlUnitId);
    await _p.setString('mrcNo', mrcNo);
    await _p.setString('initAt', initAt);
    if (lastSaleInvcNo == null) {
      await _p.remove('lastSaleInvcNo');
    } else {
      await _p.setInt('lastSaleInvcNo', lastSaleInvcNo!);
    }
    await _p.setString('businessName', businessName);
    await _p.setString('address', address);
    await _p.setString('phone', phone);
    await _p.setString('email', email);
    await _p.setString('header', header);
    await _p.setString('footer', footer);
    await _p.setString('logoPath', logoPath);
    await _p.setInt('paperMm', paperMm);
    await _p.setBool('taxableInclVat', taxableInclVat);
    await _p.setString('cashier', cashier);
    notifyListeners();
  }
}
