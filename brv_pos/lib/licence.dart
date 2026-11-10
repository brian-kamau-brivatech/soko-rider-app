import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hc;
import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'session.dart';
import 'settings.dart';

/// Licences by days, made by BRV with the BRV Licence Maker (same private key as BRV PDF ETR)
/// and checked here with the public key. A licence is for ONE device (its device code).
///
/// Key layout (base32, dashes every 5): version(1) machine(5) issued-day(2) expiry-day(2) serial(4)
/// + Ed25519 signature(64). Days count from 1 Jan 2024. Version 1/2 = licence, 9 = technician key.
///
/// Without a licence the app runs a free trial (14 days from the first start). When the licence
/// ends, selling stops; receipts, reprints, reports and backups keep working.
enum LicState { ok, warn, trial, expired, none, clock, otherDevice }

class LicenceInfo {
  final int version;
  final String machine; // 8 base32 characters, no dash
  final DateTime issued;
  final DateTime expires;
  final int serial;
  LicenceInfo(this.version, this.machine, this.issued, this.expires, this.serial);
  bool get isLicence => version == 1 || version == 2;
  bool get isTechKey => version == 9;
}

class Licence extends ChangeNotifier {
  Licence._();
  static final Licence i = Licence._();
  static const _ch = MethodChannel('brv/print');

  static const contact = 'BRV Integrated Systems · 0724 679 744 · 0782 373 027';
  static const trialDays = 14;
  static final Uint8List _pub = _hex('fd61709630db5b1d71b54f816201e8179df0f9a9c1884afd8303051b021ba89e');

  String code = ''; // device code, e.g. 7K2P-9QXA
  String key = '';
  LicState state = LicState.none;
  String message = '';
  int daysLeft = 0;
  DateTime? expires;

  bool get canSell => state == LicState.ok || state == LicState.warn || state == LicState.trial;
  bool get needsAttention => state != LicState.ok;
  String get plainCode => code.replaceAll('-', '');

  Future<void> load() async {
    try {
      code = await _deviceCode();
      final p = await SharedPreferences.getInstance();
      key = p.getString('licence') ?? '';
      if ((p.getString('lic_first') ?? '').isEmpty) await p.setString('lic_first', _ymd(_today()));
      await refresh();
    } catch (e) {
      _set(LicState.none, 'Could not check the licence: $e', 0, null);
    }
  }

  /// Works out the licence state again (call before every sale: the day may have changed).
  Future<void> refresh() async {
    final p = await SharedPreferences.getInstance();
    final today = _today();
    final seen = DateTime.tryParse(p.getString('lic_seen') ?? '');
    if (seen != null && today.isBefore(seen.subtract(const Duration(days: 1)))) {
      _set(LicState.clock,
          'The date on this device (${dmy(today)}) is earlier than a date already used (${dmy(seen)}). '
          'Set the correct date and time in Android settings.',
          0, null);
      return;
    }
    if (seen == null || today.isAfter(seen)) await p.setString('lic_seen', _ymd(today));

    String problem = '';
    if (key.isNotEmpty) {
      final (info, err) = await read(key);
      if (info == null) {
        problem = err;
      } else if (!info.isLicence) {
        problem = 'The saved key is a technician key, not a licence.';
      } else if (info.machine != plainCode) {
        _set(LicState.otherDevice,
            'This licence is for another device (${_dash(info.machine)}). This device is $code. Ask BRV for a licence for $code.',
            0, info.expires);
        return;
      } else {
        final left = info.expires.difference(today).inDays;
        if (left < 0) {
          _set(LicState.expired, 'The licence ended on ${dmy(info.expires)}. Selling is stopped. Contact BRV to renew (device $code).',
              left, info.expires);
        } else {
          _set(left <= 7 ? LicState.warn : LicState.ok,
              'Licensed until ${dmy(info.expires)} ($left day${left == 1 ? '' : 's'} left).', left, info.expires);
        }
        return;
      }
    }
    final first = DateTime.tryParse(p.getString('lic_first') ?? '') ?? today;
    final end = DateTime(first.year, first.month, first.day + trialDays);
    final left = end.difference(today).inDays;
    if (left >= 0) {
      _set(LicState.trial,
          '${problem.isEmpty ? '' : '$problem '}Free trial: $left day${left == 1 ? '' : 's'} left. Send device code $code to BRV for a licence.',
          left, end);
    } else {
      _set(LicState.none,
          '${problem.isEmpty ? 'No licence.' : problem} The free trial has ended, so selling is stopped. Send device code $code to BRV for a licence.',
          left, null);
    }
  }

  /// Saves a licence key (the text may be the whole WhatsApp message). Returns an error or null.
  Future<String?> activate(String text) async {
    final k = extractKey(text);
    if (k.isEmpty) return 'Paste the licence key from BRV.';
    final (info, err) = await read(k);
    if (info == null) return err;
    if (info.isTechKey) return 'This is a technician key (for unlocking settings), not a licence.';
    if (!info.isLicence) return 'This key is not a BRV POS licence.';
    if (info.machine != plainCode) {
      return 'This licence is for device ${_dash(info.machine)}, but this device is $code.';
    }
    if (info.expires.isBefore(_today())) return 'This licence already ended on ${dmy(info.expires)}.';
    final p = await SharedPreferences.getInstance();
    await p.setString('licence', k);
    key = k;
    await refresh();
    return null;
  }

  void _set(LicState st, String msg, int left, DateTime? exp) {
    state = st;
    message = msg;
    daysLeft = left;
    expires = exp;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------

  /// Reads and checks a key. Returns (info, '') or (null, error).
  static Future<(LicenceInfo?, String)> read(String key) async {
    Uint8List raw;
    try {
      raw = b32decode(key);
    } catch (_) {
      return (null, 'This is not a licence key.');
    }
    if (raw.length != 14 + 64) return (null, 'This is not a licence key (wrong length). Copy the whole key.');
    final body = Uint8List.fromList(raw.sublist(0, 14));
    final sig = Uint8List.fromList(raw.sublist(14));
    bool ok = false;
    try {
      ok = await cg.Ed25519().verify(
        body,
        signature: cg.Signature(sig, publicKey: cg.SimplePublicKey(_pub, type: cg.KeyPairType.ed25519)),
      );
    } catch (_) {
      ok = false;
    }
    if (!ok) return (null, 'This key is not valid. Copy it again exactly as BRV sent it.');
    final bd = ByteData.sublistView(body);
    final iss = bd.getUint16(6);
    final exp = bd.getUint16(8);
    return (
      LicenceInfo(body[0], b32encode(body.sublist(1, 6)), DateTime(2024, 1, 1 + iss), DateTime(2024, 1, 1 + exp), bd.getUint32(10)),
      ''
    );
  }

  /// Finds the key in pasted text (a WhatsApp message with words around it is fine).
  static String extractKey(String text) {
    final up = text.toUpperCase();
    final re = RegExp(r'[A-Z2-7]{5}(?:-[A-Z2-7]{1,5}){12,}');
    final m = re.firstMatch(up);
    if (m != null) return m.group(0)!;
    final joined = up.replaceAll(RegExp(r'\s'), '');
    final m2 = re.firstMatch(joined);
    if (m2 != null) return m2.group(0)!;
    return joined.replaceAll(RegExp(r'[^A-Z2-7]'), '');
  }

  static Future<String> _deviceCode() async {
    String id = '';
    try {
      id = await _ch.invokeMethod<String>('deviceId') ?? '';
    } catch (_) {}
    if (id.isEmpty) {
      // No Android ID: use a random id kept on this device.
      final p = await SharedPreferences.getInstance();
      id = p.getString('lic_fallback_id') ?? '';
      if (id.isEmpty) {
        final r = Random.secure();
        id = 'R${List<int>.generate(12, (_) => r.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
        await p.setString('lic_fallback_id', id);
      }
    }
    final h = hc.sha256.convert(utf8.encode('BRV-POS:$id')).bytes.sublist(0, 5);
    return _dash(b32encode(h));
  }

  static String _dash(String s) => s.length == 8 ? '${s.substring(0, 4)}-${s.substring(4)}' : s;
  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static String dmy(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static Uint8List _hex(String s) =>
      Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
}

const _b32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// RFC 4648 base32 without padding (same as Python's base64.b32encode, '=' removed).
String b32encode(List<int> data) {
  final out = StringBuffer();
  var buf = 0, bits = 0;
  for (final b in data) {
    buf = (buf << 8) | (b & 0xFF);
    bits += 8;
    while (bits >= 5) {
      out.write(_b32[(buf >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buf &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_b32[(buf << (5 - bits)) & 31]);
  return out.toString();
}

/// Base32 to bytes; dashes, spaces and '=' are ignored.
Uint8List b32decode(String s) {
  final clean = s.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '');
  final out = <int>[];
  var buf = 0, bits = 0;
  for (final ch in clean.split('')) {
    final v = _b32.indexOf(ch);
    if (v < 0) throw const FormatException('not base32');
    buf = (buf << 5) | v;
    bits += 5;
    if (bits >= 8) {
      out.add((buf >> (bits - 8)) & 0xFF);
      bits -= 8;
    }
    buf &= (1 << bits) - 1;
  }
  return Uint8List.fromList(out);
}

/// The BRV technician lock: VSCU, PIN, branch, serial, receipt header, invoice numbering and
/// restore can only be changed after unlocking with the technician PIN (15 minutes).
/// The PIN is made the first time on a new install, or with a technician key from the
/// BRV Licence Maker (valid 2 days, for this device only), which also resets a forgotten PIN.
class Tech {
  static DateTime? _until;
  static bool get unlocked => _until != null && DateTime.now().isBefore(_until!);
  static void lock() => _until = null;
  static void open() => _until = DateTime.now().add(const Duration(minutes: 15));

  static Future<bool> hasPin() async => ((await SharedPreferences.getInstance()).getString('tech_hash') ?? '').isNotEmpty;

  /// A brand-new install may create the PIN without a technician key.
  static bool get freeSetup => !Settings.i.initialised;

  static Future<bool> checkPin(String pin) async {
    final p = await SharedPreferences.getInstance();
    final salt = p.getString('tech_salt') ?? '';
    final hash = p.getString('tech_hash') ?? '';
    return hash.isNotEmpty && Session.hash(pin.trim(), salt) == hash;
  }

  static Future<void> setPin(String pin) async {
    final p = await SharedPreferences.getInstance();
    final r = Random.secure();
    final salt = base64Url.encode(List<int>.generate(16, (_) => r.nextInt(256)));
    await p.setString('tech_salt', salt);
    await p.setString('tech_hash', Session.hash(pin.trim(), salt));
  }

  /// Checks a technician key for this device. Returns an error or null.
  static Future<String?> checkKey(String text) async {
    final k = Licence.extractKey(text);
    if (k.isEmpty) return 'Paste the technician key.';
    final (info, err) = await Licence.read(k);
    if (info == null) return err;
    if (!info.isTechKey) return 'This is a licence key. Make a technician key in the BRV Licence Maker.';
    if (info.machine != Licence.i.plainCode) {
      return 'This technician key is for device ${Licence._dash(info.machine)}, this device is ${Licence.i.code}.';
    }
    final today = Licence._today();
    if (today.isBefore(info.issued.subtract(const Duration(days: 1))) || today.isAfter(info.expires)) {
      return 'This technician key has expired (valid until ${Licence.dmy(info.expires)}). Make a new one.';
    }
    return null;
  }
}
