import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'fmt.dart';
import 'master.dart';

const pinRounds = 3000;

String hashPin(String pin, String salt) {
  var h = sha256.convert(utf8.encode(salt + pin)).toString();
  for (var i = 0; i < pinRounds - 1; i++) {
    h = sha256.convert(utf8.encode(salt + h)).toString();
  }
  return h;
}

String otpHash(String otp, String waybill) => sha256.convert(utf8.encode('$waybill:$otp')).toString();

bool checkPin(Map<String, dynamic> staff, String pin) {
  final salt = s(staff['pin_salt']), want = s(staff['pin_hash']);
  if (salt.isEmpty || want.isEmpty) return false;
  return hashPin(pin, salt) == want;
}

/// Who is using the terminal now (tap name + PIN; works offline).
class Session extends ChangeNotifier {
  static final Session i = Session._();
  Session._();

  Map<String, dynamic>? staff;
  int get id => n(staff?['id']);
  String get name => s(staff?['name']);
  String get role => s(staff?['role']);
  bool get signedIn => staff != null;
  bool get isSupervisor => role == 'supervisor';
  bool get canBook => role == 'clerk' || isSupervisor;
  bool get canLoad => role == 'loader' || isSupervisor;
  bool get canCollect => role == 'clerk' || isSupervisor;

  /// Staff allowed on this terminal: those of this branch plus staff with no branch (drivers).
  List<Map<String, dynamic>> users() {
    final hub = Master.i.hubId;
    final l = Master.i.staff.where((st) => n(st['hub_id']) == 0 || n(st['hub_id']) == hub).toList();
    l.sort((a, b) => s(a['name']).compareTo(s(b['name'])));
    return l;
  }

  List<Map<String, dynamic>> supervisors() => Master.i.staff.where((st) => st['role'] == 'supervisor').toList();

  String? signIn(Map<String, dynamic> st, String pin) {
    if (s(st['pin_hash']).isEmpty) return 'No PIN set for ${st['name']}. Ask the administrator to set it in Odoo.';
    if (!checkPin(st, pin)) return 'Wrong PIN.';
    staff = st;
    touch();
    notifyListeners();
    return null;
  }

  /// PIN already checked by the PIN dialog.
  void forceSignIn(Map<String, dynamic> st) {
    staff = st;
    touch();
    notifyListeners();
  }

  void lock() {
    staff = null;
    notifyListeners();
  }

  // ---------------------------------------------------------- auto-lock
  DateTime _last = DateTime.now();
  Timer? _t;
  void touch() => _last = DateTime.now();
  void startIdleWatch() {
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 20), (_) {
      final mins = Master.i.num_('idle_lock_minutes', 10);
      if (signedIn && mins > 0 && DateTime.now().difference(_last).inSeconds > mins * 60) lock();
    });
  }
}
