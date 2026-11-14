import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';
import 'db.dart';
import 'net.dart';

/// This device's link to a company on the BRV server: device code, token, licence end date.
/// The licence counts down by the day even offline, and is refreshed at every sync.
class Licence extends ChangeNotifier {
  Licence._();
  static final Licence i = Licence._();

  late SharedPreferences _p;
  String code = '';
  String _secret = '';
  String token = '';
  String server = defaultServer;
  String status = 'none'; // none | waiting | active | expired | suspended | revoked
  String role = '';
  String company = '';
  int companyId = 0;
  int deviceNo = 0;
  int deviceId = 0;
  int maxDevices = 0;
  int devicesUsed = 0;
  bool seeded = false;
  DateTime? expiresAt;
  DateTime? lastServerTime;
  DateTime? lastSeen; // latest device clock seen: stops winding the clock back
  String message = '';

  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    code = _p.getString('lic_code') ?? '';
    _secret = _p.getString('lic_secret') ?? '';
    if (code.isEmpty || _secret.isEmpty) {
      final r = Random.secure();
      code = (isManagerApp ? 'M' : 'S') + List.generate(11, (_) => _alphabet[r.nextInt(_alphabet.length)]).join();
      _secret = base64Url.encode(List<int>.generate(32, (_) => r.nextInt(256)));
      await _p.setString('lic_code', code);
      await _p.setString('lic_secret', _secret);
    }
    token = _p.getString('lic_token') ?? '';
    server = defaultServer; // built into the app, never shown or changed
    status = _p.getString('lic_status') ?? 'none';
    role = _p.getString('lic_role') ?? '';
    company = _p.getString('lic_company') ?? '';
    companyId = _p.getInt('lic_company_id') ?? 0;
    deviceNo = _p.getInt('lic_device_no') ?? 0;
    deviceId = _p.getInt('lic_device_id') ?? 0;
    maxDevices = _p.getInt('lic_max') ?? 0;
    devicesUsed = _p.getInt('lic_used') ?? 0;
    seeded = _p.getBool('lic_seeded') ?? false;
    expiresAt = DateTime.tryParse(_p.getString('lic_expires') ?? '');
    lastServerTime = DateTime.tryParse(_p.getString('lic_server_time') ?? '');
    lastSeen = DateTime.tryParse(_p.getString('lic_last_seen') ?? '');
    Db.deviceNo = deviceNo;
    _tick();
  }

  /// Code shown to the developer / manager: MXXX-XXXX-XXXX.
  String get shownCode => code.length == 12 ? '${code.substring(0, 4)}-${code.substring(4, 8)}-${code.substring(8)}' : code;

  DateTime get _clock {
    final now = DateTime.now();
    return lastSeen != null && lastSeen!.isAfter(now) ? lastSeen! : now;
  }

  /// The phone's clock was put back more than a day: a sync is needed to continue.
  bool get clockTampered => lastSeen != null && DateTime.now().isBefore(lastSeen!.subtract(const Duration(days: 1)));

  int get daysLeft {
    final e = expiresAt;
    if (e == null) return 0;
    final sec = e.difference(_clock).inSeconds;
    return sec <= 0 ? 0 : (sec / 86400).ceil();
  }

  bool get linked => token.isNotEmpty && companyId > 0;
  bool get usable => linked && status == 'active' && daysLeft > 0 && !clockTampered;

  void _tick() {
    final now = DateTime.now();
    if (lastSeen == null || now.isAfter(lastSeen!)) {
      lastSeen = now;
      _p.setString('lic_last_seen', now.toIso8601String());
    }
  }

  /// Asks the server about this device. Waiting until BRV (manager) or the manager (sales) adds the code.
  Future<void> hello() async {
    _tick();
    try {
      final r = await Net.call(server, 'POST', '/hello', body: {
        'code': code, 'secret': _secret, 'app': isManagerApp ? 'manager' : 'sales', 'model': defaultTargetPlatform.name,
      });
      final st = '${r['status']}';
      if (r['token'] != null) {
        token = '${r['token']}';
        deviceNo = (r['device_no'] as num?)?.toInt() ?? deviceNo;
        deviceId = (r['device_id'] as num?)?.toInt() ?? deviceId;
        role = '${r['role'] ?? role}';
        await _p.setString('lic_token', token);
        await _p.setInt('lic_device_no', deviceNo);
        await _p.setInt('lic_device_id', deviceId);
        await _p.setString('lic_role', role);
        Db.deviceNo = deviceNo;
      }
      if (r['licence'] is Map) await apply(Map<String, dynamic>.from(r['licence'] as Map));
      await _setStatus(st);
      message = '';
    } on NetError catch (e) {
      message = e.message;
      if (e.status == 403) await _setStatus('revoked');
    }
    notifyListeners();
  }

  /// Licence part of a sync / hello answer.
  Future<void> apply(Map<String, dynamic> l) async {
    company = '${l['company'] ?? company}';
    companyId = (l['company_id'] as num?)?.toInt() ?? companyId;
    maxDevices = (l['max_devices'] as num?)?.toInt() ?? maxDevices;
    devicesUsed = (l['devices_used'] as num?)?.toInt() ?? devicesUsed;
    seeded = l['seeded'] == true || seeded;
    expiresAt = DateTime.tryParse('${l['expires_at']}')?.toLocal() ?? expiresAt;
    lastServerTime = DateTime.tryParse('${l['server_time']}')?.toLocal() ?? lastServerTime;
    // trust the server's time over a wound-back phone clock
    if (lastServerTime != null && (lastSeen == null || lastServerTime!.isAfter(lastSeen!))) {
      lastSeen = lastServerTime;
      await _p.setString('lic_last_seen', lastSeen!.toIso8601String());
    }
    await _p.setString('lic_company', company);
    await _p.setInt('lic_company_id', companyId);
    await _p.setInt('lic_max', maxDevices);
    await _p.setInt('lic_used', devicesUsed);
    await _p.setBool('lic_seeded', seeded);
    if (expiresAt != null) await _p.setString('lic_expires', expiresAt!.toIso8601String());
    if (lastServerTime != null) await _p.setString('lic_server_time', lastServerTime!.toIso8601String());
    if (l['active'] == false) {
      await _setStatus('suspended');
    } else if ((l['days_left'] as num?)?.toInt() == 0) {
      await _setStatus('expired');
    } else if (status == 'expired' || status == 'suspended') {
      await _setStatus('active');
    }
    notifyListeners();
  }

  Future<void> _setStatus(String st) async {
    status = st;
    await _p.setString('lic_status', st);
  }

  Future<void> markRevoked() async {
    await _setStatus('revoked');
    notifyListeners();
  }

  Map<String, String> get auth => {'Authorization': 'Bearer $token'};

  /// Short fingerprint of the server answer (shown in hidden settings for support).
  String get fingerprint => sha256.convert(utf8.encode('$code$companyId$deviceNo')).toString().substring(0, 8);
}
