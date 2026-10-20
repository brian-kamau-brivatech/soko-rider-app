import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'odoo_service.dart';

/// Firebase settings come from the build (GitHub secrets → --dart-define), so
/// nothing secret is stored in the code. If they are missing, push is simply
/// off and the app still checks for requests itself while the rider is Online.
class _FirebaseEnv {
  static const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const senderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

  static bool get configured => apiKey.isNotEmpty && appId.isNotEmpty && senderId.isNotEmpty && projectId.isNotEmpty;
}

/// Runs when a push arrives while the app is closed. The system already shows
/// the notification; nothing else to do here.
@pragma('vm:entry-point')
Future<void> _backgroundHandler(RemoteMessage message) async {}

class PushService {
  PushService._();
  static final PushService instance = PushService._();

  bool enabled = false;
  String? status; // shown on the Profile screen

  /// Called when a push arrives or is tapped, so the app fetches the request.
  VoidCallback? onDispatchPush;

  Future<void> init() async {
    if (!_FirebaseEnv.configured) {
      status = 'Push alerts not set up in this build';
      return;
    }
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: _FirebaseEnv.apiKey,
          appId: _FirebaseEnv.appId,
          messagingSenderId: _FirebaseEnv.senderId,
          projectId: _FirebaseEnv.projectId,
        ),
      );
      FirebaseMessaging.onBackgroundMessage(_backgroundHandler);
      FirebaseMessaging.onMessage.listen((_) => onDispatchPush?.call());
      FirebaseMessaging.onMessageOpenedApp.listen((_) => onDispatchPush?.call());
      enabled = true;
      status = 'Push alerts on';
    } catch (e) {
      status = 'Push alerts failed to start';
      debugPrint('Firebase init failed: $e');
    }
  }

  /// Ask for notification permission and give Soko this phone's push address.
  Future<void> registerWith(OdooService service) async {
    if (!enabled) return;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(alert: true, sound: true, badge: true);
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        status = 'Notifications blocked: allow them in phone Settings';
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await service.registerPushToken(token);
      FirebaseMessaging.instance.onTokenRefresh.listen(service.registerPushToken);
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) onDispatchPush?.call();
    } catch (e) {
      debugPrint('Push registration failed: $e');
    }
  }
}
