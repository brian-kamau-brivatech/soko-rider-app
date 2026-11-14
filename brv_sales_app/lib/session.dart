import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'config.dart';
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

  /// The open session (cash drawer) of this terminal, whoever opened it.
  static Future<Map<String, Object?>?> openSession() => Db.one(
      "SELECT sh.*, u.name AS opener FROM shifts sh LEFT JOIN users u ON u.id = sh.user_id "
      "WHERE sh.state = 'open' AND sh.device_no = ? ORDER BY sh.id DESC LIMIT 1",
      [Db.deviceNo]);

  /// PIN checks run off the screen thread so the app does not freeze.
  static Future<String> hashPinAsync(String pin, String salt) => compute(_hashWorker, [pin, salt]);

  /// Index of the first (id, salt, hash) whose hash matches the PIN, or -1.
  static Future<int> _match(String pin, List<List<String>> users) => compute(_matchWorker, [pin, users]);

  /// May this person sign in to this app? (The manager app is only for manager-level users.)
  static bool allowedHere(Map<String, Object?> u) =>
      !isManagerApp || n(u['owner']) == 1 || s(u['perms']).split(',').contains(P.managerApp);

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
    final users = await Db.q('SELECT id, pin_salt, pin_hash FROM users WHERE id != ?', [exceptId]);
    return await _match(pin, [for (final u in users) [s(u['id']), s(u['pin_salt']), s(u['pin_hash'])]]) >= 0;
  }

  static Future<int> createUser({required String name, required String pin, required int roleId, String phone = '', bool owner = false}) async {
    final db = await Db.get();
    final salt = newSalt();
    return Db.ins(db, 'users', {
      'name': name.trim(),
      'phone': phone.trim(),
      'role_id': roleId,
      'pin_salt': salt,
      'pin_hash': await hashPinAsync(pin, salt),
      'owner': owner ? 1 : 0,
      'active': 1,
      'created_at': nowIso(),
    });
  }

  static Future<void> setPin(int userId, String pin) async {
    final db = await Db.get();
    final salt = newSalt();
    await db.update('users', {'pin_salt': salt, 'pin_hash': await hashPinAsync(pin, salt), 'fails': 0, 'locked_until': ''},
        where: 'id = ?', whereArgs: [userId]);
  }

  /// Checks the PIN of the chosen user. Returns an error text, or null when signed in.
  Future<String?> signIn(int id, String pin) async {
    final db = await Db.get();
    final u = await Db.one('SELECT u.*, r.perms FROM users u LEFT JOIN roles r ON r.id = u.role_id WHERE u.id = ? AND u.active = 1', [id]);
    if (u == null) return 'This user is not active.';
    if (!allowedHere(u)) return 'This app is for managers. Sign in on a BRV Pos Sales device.';
    final until = DateTime.tryParse(s(u['locked_until']));
    if (until != null && until.isAfter(DateTime.now())) {
      final m = until.difference(DateTime.now()).inMinutes + 1;
      return 'Too many wrong PINs. Try again in $m min, or ask a manager to reset the PIN.';
    }
    if (await hashPinAsync(pin, s(u['pin_salt'])) != s(u['pin_hash'])) {
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
    final users = await Db.q('SELECT u.*, r.perms FROM users u LEFT JOIN roles r ON r.id = u.role_id WHERE u.active = 1');
    final k = await _match(pin, [for (final u in users) [s(u['id']), s(u['pin_salt']), s(u['pin_hash'])]]);
    if (k < 0) return null;
    final u = users[k];
    if (right == null || n(u['owner']) == 1 || s(u['perms']).split(',').contains(right)) return u;
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
    // a shift is one person's cash drawer on this device
    shift = await openSession();
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

String _hashWorker(List<String> a) => Session.hashPin(a[0], a[1]);

int _matchWorker(List<Object> a) {
  final pin = a[0] as String;
  final users = (a[1] as List).cast<List<String>>();
  for (var k = 0; k < users.length; k++) {
    if (Session.hashPin(pin, users[k][1]) == users[k][2]) return k;
  }
  return -1;
}
