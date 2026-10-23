import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'db.dart';
import 'settings.dart';

/// Everything BRV POS keeps, in one compressed file saved in
/// Downloads/BRV POS/Backups. That folder stays when the app is uninstalled,
/// so a new install can bring it all back with Restore.
class Backup {
  static const _ch = MethodChannel('brv/print');
  static const tables = ['items', 'sales', 'sale_lines', 'kv', 'users', 'customers', 'z_reports'];
  // Device-only keys that must not travel in a backup.
  static const _skipPrefs = {'signed_in_user', 'auto_backup_uri', 'auto_backup_day', 'auto_backup_list', 'last_backup_at'};

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// Builds the backup file (gzip-compressed JSON).
  static Future<List<int>> build() async {
    final db = await Db.get();
    final data = <String, dynamic>{};
    for (final t in tables) {
      data[t] = await db.query(t);
    }
    final prefs = await SharedPreferences.getInstance();
    final pm = <String, dynamic>{};
    for (final k in prefs.getKeys()) {
      if (!_skipPrefs.contains(k)) pm[k] = prefs.get(k);
    }
    String? logo, logoExt;
    final lp = Settings.i.logoPath;
    if (lp.isNotEmpty && File(lp).existsSync()) {
      logo = base64Encode(await File(lp).readAsBytes());
      logoExt = p.extension(lp);
    }
    final json = jsonEncode({
      'app': 'BRV POS',
      'format': 1,
      'created': DateTime.now().toIso8601String(),
      'tin': Settings.i.tin,
      'bhfId': Settings.i.bhfId,
      'shop': Settings.i.shopName,
      'prefs': pm,
      'tables': data,
      'logo': logo,
      'logoExt': logoExt,
    });
    return gzip.encode(utf8.encode(json));
  }

  static const fileName = 'BRV-POS-backup.brvpos';

  /// Saves the backup now, over the same single file. [share] opens the share sheet.
  static Future<String?> saveNow({bool share = false}) => _write(share: share);

  static bool _autoRunning = false;

  /// Refreshes the one backup file (after each sale, Z report and at start-up).
  static Future<void> auto() async {
    if (_autoRunning) return;
    _autoRunning = true;
    try {
      await _write();
    } catch (_) {
      // a failed automatic backup must never disturb selling
    } finally {
      _autoRunning = false;
    }
  }

  /// Always writes over the same file in Downloads/BRV POS/Backups.
  static Future<String?> _write({bool share = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final uri = await _ch.invokeMethod<String>('saveBackup', {
      'bytes': Uint8List.fromList(await build()),
      'name': fileName,
      'uri': prefs.getString('auto_backup_uri'),
      'share': share,
    });
    if (uri == null) return null;
    await prefs.setString('auto_backup_uri', uri);
    // Tidy up daily files made by the previous version.
    for (final old in prefs.getStringList('auto_backup_list') ?? const <String>[]) {
      if (old == uri) continue;
      try {
        await _ch.invokeMethod('deleteUri', {'uri': old});
      } catch (_) {}
    }
    await prefs.remove('auto_backup_list');
    await _stamp();
    return uri;
  }

  static Future<void> _stamp() async =>
      (await SharedPreferences.getInstance()).setString('last_backup_at', DateTime.now().toIso8601String());

  static Future<DateTime?> lastBackup() async =>
      DateTime.tryParse((await SharedPreferences.getInstance()).getString('last_backup_at') ?? '');

  /// Lets the user pick a backup file. Returns its contents, or null.
  static Future<Map<String, dynamic>?> pick() async {
    final bytes = await _ch.invokeMethod<Uint8List>('pickFile');
    if (bytes == null) return null;
    try {
      final m = jsonDecode(utf8.decode(gzip.decode(bytes)));
      if (m is Map && m['app'] == 'BRV POS' && m['tables'] is Map) return Map<String, dynamic>.from(m);
    } catch (_) {}
    throw const FormatException('This is not a BRV POS backup file.');
  }

  static String summary(Map<String, dynamic> b) {
    final t = b['tables'] as Map;
    int n(String k) => (t[k] as List?)?.length ?? 0;
    final c = DateTime.tryParse('${b['created']}');
    final when = c == null ? '' : '${_two(c.day)}/${_two(c.month)}/${c.year} ${_two(c.hour)}:${_two(c.minute)}';
    return '${b['shop'] ?? ''} · PIN ${b['tin'] ?? ''} branch ${b['bhfId'] ?? ''}\n'
        'Made $when\n'
        '${n('sales')} sales · ${n('items')} items · ${n('customers')} customers · ${n('users')} users · ${n('z_reports')} Z reports';
  }

  /// Replaces everything on this phone with the backup.
  static Future<void> restore(Map<String, dynamic> b) async {
    final db = await Db.get();
    final t = Map<String, dynamic>.from(b['tables'] as Map);
    await db.transaction((tx) async {
      for (final name in tables) {
        await tx.delete(name);
        for (final row in (t[name] as List? ?? const [])) {
          await tx.insert(name, Map<String, Object?>.from(row as Map));
        }
      }
    });
    final prefs = await SharedPreferences.getInstance();
    final pm = Map<String, dynamic>.from(b['prefs'] as Map? ?? {});
    for (final e in pm.entries) {
      final v = e.value;
      if (v is bool) {
        await prefs.setBool(e.key, v);
      } else if (v is int) {
        await prefs.setInt(e.key, v);
      } else if (v is double) {
        await prefs.setDouble(e.key, v);
      } else if (v is String) {
        await prefs.setString(e.key, v);
      } else if (v is List) {
        await prefs.setStringList(e.key, v.map((x) => '$x').toList());
      }
    }
    // Logo: write it into this install's own folder.
    final logo = b['logo'];
    if (logo is String && logo.isNotEmpty) {
      final dir = await getApplicationDocumentsDirectory();
      final f = File(p.join(dir.path, 'logo_restored_${DateTime.now().millisecondsSinceEpoch}${b['logoExt'] ?? '.png'}'));
      await f.writeAsBytes(base64Decode(logo));
      await prefs.setString('logoPath', f.path);
    } else {
      await prefs.setString('logoPath', '');
    }
    await prefs.remove('signed_in_user');
    await Settings.i.load();
  }

  /// A fresh install: no sales yet and only the default admin.
  static Future<bool> isFresh() async {
    final db = await Db.get();
    final s = (await db.rawQuery('SELECT COUNT(*) c FROM sales')).first['c'] as int? ?? 0;
    final u = (await db.rawQuery('SELECT COUNT(*) c FROM users')).first['c'] as int? ?? 0;
    return s == 0 && u <= 1;
  }
}
