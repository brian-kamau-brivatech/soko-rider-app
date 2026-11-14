import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'db.dart';
import 'fmt.dart';
import 'perms.dart';

/// Who is using the app now. Several people share one phone: each signs in with their PIN.
class Session extends ChangeNotifier {
  Session._();
  static final Session i = Session._();

  Map<String, Object?>? user;
  Set<String> rights = {};
  String roleName = '';
  Map<String, Object?>? shift; // this user's open shift

  bool get signedIn => user != null;
  int get userId => n(user?['id']);
  String get name => s(user?['name']);
  bool get owner => n(user?['owner']) == 1;
  bool can(String right) => owner || rights.contains(right);

  static String newSalt() {
    final r = Random.secure();
    return base64Url.encode(List<int>.generate(16, (_) => r.nextInt(256)));
  }

  /// Salted, stretched SHA-256: the PIN itself is never stored.
  static String hashPin(String pin, String salt) {
    List<int> h = utf8.encode('$salt|$pin|brv-pos-sales');
    for (var k = 0; k < 6000; k++) {
      h = sha256.convert(h).bytes;
    }
    return base64Url.encode(h);
  }

  static bool pinOk(String pin) => RegExp(r'^\d{4,6}$').hasMatch(pin);

  /// Recovery code for the owner (shown once at set-up, used if the owner forgets the PIN).
  static String newRecoveryCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(10, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static Future<bool> anyUsers() async => await Db.count('SELECT COUNT(*) FROM users') > 0;

  /// PINs must be different for everyone (a PIN identifies the person on the receipt and in reports).
  static Future<bool> pinTaken(String pin, {int exceptId = 0}) async {
    for (final u in await Db.q('SELECT id, pin_salt, pin_hash FROM users WHERE id != ?', [exceptId])) {
      if (hashPin(pin, s(u['pin_salt'])) == s(u['pin_hash'])) return true;
    }
    return false;
  }

  static Future<int> createUser({required String name, required String pin, required int roleId, String phone = '', bool owner = false}) async {
    final db = await Db.get();
    final salt = newSalt();
    return db.insert('users', {
      'name': name.trim(),
      'phone': phone.trim(),
      'role_id': roleId,
      'pin_salt': salt,
      'pin_hash': hashPin(pin, salt),
      'owner': owner ? 1 : 0,
      'active': 1,
      'created_at': nowIso(),
    });
  }

  static Future<void> setPin(int userId, String pin) async {
    final db = await Db.get();
    final salt = newSalt();
    await db.update('users', {'pin_salt': salt, 'pin_hash': hashPin(pin, salt), 'fails': 0, 'locked_until': ''},
        where: 'id = ?', whereArgs: [userId]);
  }

  /// Checks the PIN of the chosen user. Returns an error text, or null when signed in.
  Future<String?> signIn(int id, String pin) async {
    final db = await Db.get();
    final u = await Db.one('SELECT * FROM users WHERE id = ? AND active = 1', [id]);
    if (u == null) return 'This user is not active.';
    final until = DateTime.tryParse(s(u['locked_until']));
    if (until != null && until.isAfter(DateTime.now())) {
      final m = until.difference(DateTime.now()).inMinutes + 1;
      return 'Too many wrong PINs. Try again in $m min, or ask a manager to reset the PIN.';
    }
    if (hashPin(pin, s(u['pin_salt'])) != s(u['pin_hash'])) {
      final fails = n(u['fails']) + 1;
      await db.update('users', {
        'fails': fails >= 5 ? 0 : fails,
        'locked_until': fails >= 5 ? DateTime.now().add(const Duration(minutes: 5)).toIso8601String() : '',
      }, where: 'id = ?', whereArgs: [id]);
      return fails >= 5 ? 'Wrong PIN 5 times: locked for 5 minutes.' : 'Wrong PIN (${5 - fails} tries left).';
    }
    await db.update('users', {'fails': 0, 'locked_until': '', 'last_login': nowIso()}, where: 'id = ?', whereArgs: [id]);
    await _load(u);
    await Db.audit(db, userId, 'sign_in', name);
    return null;
  }

  /// Checks another person's PIN (manager approval on the spot). Returns that user, or null.
  static Future<Map<String, Object?>?> userByPin(String pin, {String? right}) async {
    for (final u in await Db.q('SELECT u.*, r.perms FROM users u JOIN roles r ON r.id = u.role_id WHERE u.active = 1')) {
      if (hashPin(pin, s(u['pin_salt'])) == s(u['pin_hash'])) {
        if (right == null || n(u['owner']) == 1 || s(u['perms']).split(',').contains(right)) return u;
        return null;
      }
    }
    return null;
  }

  Future<void> _load(Map<String, Object?> u) async {
    final r = await Db.one('SELECT * FROM roles WHERE id = ?', [u['role_id']]);
    user = u;
    rights = s(r?['perms']).split(',').where((x) => x.isNotEmpty).toSet();
    roleName = s(r?['name']);
    await refreshShift();
    touch();
    notifyListeners();
  }

  Future<void> refreshShift() async {
    shift = await Db.one("SELECT * FROM shifts WHERE user_id = ? AND state = 'open' ORDER BY id DESC LIMIT 1", [userId]);
    notifyListeners();
  }

  Future<void> reload() async {
    if (user == null) return;
    final u = await Db.one('SELECT * FROM users WHERE id = ?', [userId]);
    if (u == null || n(u['active']) != 1) {
      lock();
      return;
    }
    await _load(u);
  }

  void lock() {
    user = null;
    rights = {};
    shift = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Auto-lock when nobody touches the screen
  // ---------------------------------------------------------------------------
  Timer? _idle;
  int lockMinutes = 2;

  void touch() {
    _idle?.cancel();
    if (!signedIn || lockMinutes <= 0) return;
    _idle = Timer(Duration(minutes: lockMinutes), lock);
  }

  static List<String> get allRights => P.keys;
}
