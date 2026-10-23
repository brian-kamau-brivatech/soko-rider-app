import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'db.dart';

/// Users and who is signed in. There is no sign-up: the first account is
/// admin / Dev@96, and the admin adds everyone else under Users.
class Session extends ChangeNotifier {
  Session._();
  static final Session i = Session._();

  Map<String, dynamic>? user;

  bool get signedIn => user != null;
  bool get admin => user?['role'] == 'admin';
  int get userId => (user?['id'] as int?) ?? 0;
  String get name => '${user?['name'] ?? ''}';
  String get username => '${user?['username'] ?? ''}';

  static const defaultUser = 'admin';
  static const _defaultPass = 'Dev@96';

  static String _salt() {
    final r = Random.secure();
    return base64Url.encode(List<int>.generate(16, (_) => r.nextInt(256)));
  }

  /// Salted SHA-256, stretched, so the password itself is never stored.
  static String hash(String password, String salt) {
    List<int> d = utf8.encode('$salt:$password');
    for (var n = 0; n < 10000; n++) {
      d = sha256.convert(d).bytes;
    }
    return base64Url.encode(d);
  }

  /// Make sure the first admin account exists.
  static Future<void> ensureAdmin() async {
    final db = await Db.get();
    final n = (await db.rawQuery('SELECT COUNT(*) AS n FROM users')).first['n'] as int? ?? 0;
    if (n > 0) return;
    final salt = _salt();
    await db.insert('users', {
      'username': defaultUser,
      'name': 'Administrator',
      'role': 'admin',
      'salt': salt,
      'pass_hash': hash(_defaultPass, salt),
      'active': 1,
      'first_login': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// Check a username and password. Returns the user, or null.
  static Future<Map<String, dynamic>?> verify(String username, String password) async {
    final db = await Db.get();
    final r = await db.query('users', where: 'username = ? AND active = 1', whereArgs: [username.trim()], limit: 1);
    if (r.isEmpty) return null;
    final u = Map<String, dynamic>.from(r.first);
    return hash(password, '${u['salt']}') == u['pass_hash'] ? u : null;
  }

  void signIn(Map<String, dynamic> u) {
    user = u;
    notifyListeners();
  }

  void signOut() {
    user = null;
    notifyListeners();
  }

  Future<void> reload() async {
    if (user == null) return;
    final db = await Db.get();
    final r = await db.query('users', where: 'id = ?', whereArgs: [userId], limit: 1);
    user = r.isEmpty ? null : Map<String, dynamic>.from(r.first);
    notifyListeners();
  }

  /// Returns an error message, or null when saved.
  static Future<String?> saveUser({
    int? id,
    required String username,
    required String name,
    required String role,
    String? password,
    bool active = true,
    bool? firstLogin,
  }) async {
    final u = username.trim();
    if (!RegExp(r'^[A-Za-z0-9._@-]{3,30}$').hasMatch(u)) {
      return 'Username: 3 to 30 letters, numbers or . _ @ -';
    }
    if (name.trim().isEmpty) return 'Enter the name.';
    if (password != null) {
      final e = passwordProblem(password);
      if (e != null) return e;
    }
    final db = await Db.get();
    final clash = await db.query('users',
        where: id == null ? 'username = ?' : 'username = ? AND id != ?', whereArgs: id == null ? [u] : [u, id], limit: 1);
    if (clash.isNotEmpty) return 'The username "$u" is taken.';
    final row = <String, dynamic>{'username': u, 'name': name.trim(), 'role': role, 'active': active ? 1 : 0};
    if (password != null) {
      final salt = _salt();
      row['salt'] = salt;
      row['pass_hash'] = hash(password, salt);
    }
    if (firstLogin != null) row['first_login'] = firstLogin ? 1 : 0;
    if (id == null) {
      if (password == null) return 'Enter a password.';
      row['created_at'] = DateTime.now().toIso8601String();
      row['first_login'] = firstLogin == false ? 0 : 1;
      await db.insert('users', row);
    } else {
      if (role != 'admin' || !active) {
        // Never lock everyone out: keep at least one active admin.
        final others = await db.query('users',
            where: "role = 'admin' AND active = 1 AND id != ?", whereArgs: [id], limit: 1);
        if (others.isEmpty) return 'At least one active admin is needed.';
      }
      await db.update('users', row, where: 'id = ?', whereArgs: [id]);
    }
    if (id != null && id == i.userId) await i.reload();
    return null;
  }

  static String? passwordProblem(String p) {
    if (p.length < 6) return 'Password: at least 6 characters.';
    if (p == _defaultPass) return 'Choose a password different from the default one.';
    return null;
  }

  static Future<void> markSeen(int id) async {
    final db = await Db.get();
    await db.update('users', {'first_login': 0}, where: 'id = ?', whereArgs: [id]);
  }
}
