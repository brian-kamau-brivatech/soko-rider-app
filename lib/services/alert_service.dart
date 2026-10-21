import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'odoo_service.dart';

/// Rings the phone for a delivery request, also when the screen is locked
/// (native Android code in MainActivity.kt): wakes the screen, shows the
/// request over the lock screen, loops the chosen sound on alarm volume and
/// repeats the chosen vibration until the rider answers.
class AlertService {
  AlertService._();

  static const _channel = MethodChannel('soko/alert');
  static const _vibKey = 'alert_vibration';
  static const _soundKey = 'alert_sound';

  /// Vibration patterns the rider can pick from (key → label).
  static const vibrations = <String, String>{
    'call': 'Phone call (long buzz, pause)',
    'heartbeat': 'Heartbeat (ba-boom)',
    'rapid': 'Rapid pulse',
    'long': 'Long buzz',
    'sos': 'SOS (... --- ...)',
    'wave': 'Rising wave',
    'none': 'No vibration',
  };

  static const sounds = <String, String>{
    'ringtone': 'Phone ringtone',
    'chime': 'Soko chime',
    'alarm': 'Alarm sound',
    'none': 'Silent (vibrate only)',
  };

  static Future<String> vibration() async =>
      (await SharedPreferences.getInstance()).getString(_vibKey) ?? 'call';

  static Future<String> sound() async =>
      (await SharedPreferences.getInstance()).getString(_soundKey) ?? 'ringtone';

  static Future<void> setVibration(String key) async =>
      (await SharedPreferences.getInstance()).setString(_vibKey, key);

  static Future<void> setSound(String key) async =>
      (await SharedPreferences.getInstance()).setString(_soundKey, key);

  static Future<void> start({required String title, required String body, int seconds = 60}) async {
    try {
      await _channel.invokeMethod('start', {
        'title': title,
        'body': body,
        'vibration': await vibration(),
        'sound': await sound(),
        'seconds': seconds,
      });
    } catch (_) {}
  }

  /// Ring for a delivery request. Called as soon as the request is fetched,
  /// so it works with the screen locked (no screen has to be drawn first).
  static Future<void> startForOffer(DispatchOffer offer) {
    final o = offer.order;
    final parts = <String>[
      if (o.deliveryArea.isNotEmpty) o.deliveryArea,
      if (o.riderPayout != null) 'Payout KSh ${o.riderPayout!.toStringAsFixed(0)}',
      if (offer.riderDistanceKm != null) '${offer.riderDistanceKm!.toStringAsFixed(1)} km to shop',
    ];
    final left = offer.expiresAt.difference(DateTime.now()).inSeconds;
    return start(
      title: 'New delivery request · ${o.trackingNo}',
      body: parts.isEmpty ? 'Open Soko Rider to accept' : parts.join(' · '),
      seconds: left > 0 ? left : 60,
    );
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  static Future<void> preview({required String vibration, required String sound}) async {
    try {
      await _channel.invokeMethod('preview', {'vibration': vibration, 'sound': sound});
    } catch (_) {}
  }

  /// notifications / fullScreen / battery → true when allowed.
  static Future<Map<String, bool>> status() async {
    try {
      final m = await _channel.invokeMethod<Map>('status');
      return {for (final e in (m ?? const {}).entries) '${e.key}': e.value == true};
    } catch (_) {
      return const {};
    }
  }

  static Future<void> requestNotifications() async {
    try {
      await _channel.invokeMethod('requestNotifications');
    } catch (_) {}
  }

  static Future<void> openFullScreenSettings() async {
    try {
      await _channel.invokeMethod('openFullScreenSettings');
    } catch (_) {}
  }

  static Future<void> openBatterySettings() async {
    try {
      await _channel.invokeMethod('openBatterySettings');
    } catch (_) {}
  }

  static Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod('openAppSettings');
    } catch (_) {}
  }
}
