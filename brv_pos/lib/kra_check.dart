import 'dart:async';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'db.dart';
import 'kra.dart';
import 'sales.dart';
import 'settings.dart';

/// Is a signed sale visible on KRA's eTIMS portal? The VSCU signs at once and
/// sends to KRA in the background; this looks the receipt up on the same KRA
/// page the receipt QR code opens, and only counts it when KRA shows this
/// receipt's signature.
class KraCheck {
  static const confirmed = 1;
  static const notYet = 2;
  static bool _running = false;

  static String url(Sale s) => receiptUrl(
      test: false, tin: Settings.i.tin, bhfId: Settings.i.bhfId, rcptSign: '${s.row['rcpt_sign'] ?? ''}');

  /// Checks one sale. Returns 1 confirmed, 2 not found yet, 0 could not check (offline).
  static Future<int> check(Sale s, {bool notify = true}) async {
    final sign = '${s.row['rcpt_sign'] ?? ''}'.replaceAll('-', '').toUpperCase();
    if (!s.signed || sign.length < 8) return 0;
    int status;
    try {
      final r = await http.get(Uri.parse(url(s))).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return 0;
      final body = r.body.toUpperCase();
      // The page prints the signature in groups of 4 (e.g. RJYR-FUIT-5NM2-6MME).
      status = body.contains(hyphenate(sign)) ? confirmed : notYet;
    } catch (_) {
      return 0;
    }
    final db = await Db.get();
    await db.update('sales', {'kra_ok': status, 'kra_checked': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [s.id]);
    if (notify) salesVersion.value++;
    return status;
  }

  /// Checks recent signed sales that are not confirmed yet (newest first).
  static Future<(int, int)> checkRecent({int max = 40}) async {
    if (_running) return (0, 0);
    _running = true;
    var ok = 0, checked = 0;
    try {
      final db = await Db.get();
      final since = DateTime.now().subtract(const Duration(days: 30)).toIso8601String().substring(0, 10);
      final rows = await db.query('sales',
          columns: ['id'],
          where: "status = 'signed' AND COALESCE(kra_ok, 0) != 1 AND day >= ?",
          whereArgs: [since],
          orderBy: 'id DESC',
          limit: max);
      for (final r in rows) {
        final s = await Sale.load(r['id'] as int);
        if (s == null) continue;
        final st = await check(s, notify: false);
        if (st == 0) break; // offline: try again later
        checked++;
        if (st == confirmed) ok++;
      }
    } finally {
      _running = false;
      salesVersion.value++;
    }
    return (ok, checked);
  }

  /// Signed sales from the last 30 days not yet confirmed at KRA.
  static Future<int> unconfirmedCount() async {
    final db = await Db.get();
    final since = DateTime.now().subtract(const Duration(days: 30)).toIso8601String().substring(0, 10);
    return (await db.rawQuery(
                "SELECT COUNT(*) c FROM sales WHERE status = 'signed' AND COALESCE(kra_ok, 0) != 1 AND day >= ?", [since]))
            .first['c'] as int? ??
        0;
  }

  static Future<bool> open(Sale s) async {
    try {
      return await const MethodChannel('brv/print').invokeMethod<bool>('openUrl', {'url': url(s)}) ?? false;
    } catch (_) {
      return false;
    }
  }
}
