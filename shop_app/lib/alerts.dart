import 'package:flutter/services.dart';

/// Native ringing (same code as the rider app): wakes the screen, shows the
/// alert over the lock screen, loops the sound on alarm volume and vibrates.
class Alerts {
  static const _ch = MethodChannel('soko/alert');

  static const vibrations = <String, String>{
    'call': 'Phone call',
    'heartbeat': 'Heartbeat',
    'rapid': 'Rapid pulse',
    'long': 'Long buzz',
    'sos': 'SOS',
    'wave': 'Rising wave',
    'none': 'No vibration',
  };

  static const sounds = <String, String>{
    'ringtone': 'Phone ringtone',
    'alarm': 'Alarm sound',
    'chime': 'Soko chime',
    'none': 'Silent',
  };

  static Future<void> ring({
    required String title,
    required String body,
    required String sound,
    required String vibration,
    int seconds = 60,
  }) async {
    try {
      await _ch.invokeMethod('start', {
        'title': title,
        'body': body,
        'sound': sound,
        'vibration': vibration,
        'seconds': seconds,
      });
    } catch (_) {}
  }

  /// Short sound + buzz (rider at the shop, previews).
  static Future<void> chime(String vibration) async {
    try {
      await _ch.invokeMethod('preview', {'sound': 'chime', 'vibration': vibration});
    } catch (_) {}
  }

  static Future<void> preview(String sound, String vibration) async {
    try {
      await _ch.invokeMethod('preview', {'sound': sound, 'vibration': vibration});
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }

  static Future<void> keepAlive(bool on) async {
    try {
      await _ch.invokeMethod('keepAlive', {'on': on});
    } catch (_) {}
  }

  static Future<void> keepScreenOn(bool on) async {
    try {
      await _ch.invokeMethod('keepScreenOn', {'on': on});
    } catch (_) {}
  }

  static Future<void> requestNotifications() async {
    try {
      await _ch.invokeMethod('requestNotifications');
    } catch (_) {}
  }

  static Future<Map<String, bool>> status() async {
    try {
      final r = await _ch.invokeMethod('status');
      return Map<String, dynamic>.from(r as Map).map((k, v) => MapEntry(k, v == true));
    } catch (_) {
      return const {};
    }
  }

  static Future<void> openFullScreenSettings() => _ch.invokeMethod('openFullScreenSettings').catchError((_) {});
  static Future<void> openBatterySettings() => _ch.invokeMethod('openBatterySettings').catchError((_) {});
  static Future<void> openAppSettings() => _ch.invokeMethod('openAppSettings').catchError((_) {});
}
