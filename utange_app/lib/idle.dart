import 'dart:async';
import 'package:flutter/widgets.dart';
import 'config.dart';
import 'store.dart';

/// Utange POS: the cashier is signed out after 30 seconds without touching the screen
/// (like the Odoo POS lock screen). The next person signs in with their PIN.
class IdleLock {
  static const timeout = Duration(seconds: 30);
  static final navigatorKey = GlobalKey<NavigatorState>();
  static Timer? _t;

  static void touch() {
    if (AppConfig.isManager) return;
    _t?.cancel();
    final s = Store.i;
    if (!s.posReady || !s.cashiersOn || s.cashierToken.isEmpty) return;
    _t = Timer(timeout, _lock);
  }

  static Future<void> _lock() async {
    final s = Store.i;
    if (!s.cashiersOn || s.cashierToken.isEmpty) return;
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    await s.clearCashier();
  }
}
