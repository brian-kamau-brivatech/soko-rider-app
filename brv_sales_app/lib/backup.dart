import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'db.dart';
import 'fmt.dart';
import 'settings.dart';

/// All data in one compressed file in Downloads/BRV Pos Sales/Backups (kept if the app is removed).
/// Share it (WhatsApp, Gmail, Google Drive) to keep a copy off the phone.
class Backup {
  static const _ch = MethodChannel('brv/print');
  static const fileName = 'BRV-Pos-Sales-backup.brvsales';

  static Future<List<int>> build() async {
    final db = await Db.get();
    final data = <String, Object?>{};
    for (final t in Db.tables) {
      data[t] = await db.query(t);
    }
    return gzip.encode(utf8.encode(jsonEncode({
      'app': 'BRV Pos Sales',
      'format': 1,
      'created': nowIso(),
      'business': Settings.i.businessName,
      'tables': data,
    })));
  }

  static Future<String?> save({bool share = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final uri = await _ch.invokeMethod<String>('saveBackup', {
      'bytes': Uint8List.fromList(await build()),
      'name': fileName,
      'uri': prefs.getString('backup_uri'),
      'share': share,
    });
    if (uri != null) {
      await prefs.setString('backup_uri', uri);
      await prefs.setString('backup_at', nowIso());
    }
    return uri;
  }

  static bool _busy = false;

  /// Quiet automatic backup (after closing a shift, at start-up). Never disturbs selling.
  static Future<void> auto() async {
    if (_busy) return;
    _busy = true;
    try {
      await save();
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  static Future<DateTime?> last() async => DateTime.tryParse((await SharedPreferences.getInstance()).getString('backup_at') ?? '');

  static Future<Map<String, dynamic>?> pick() async {
    final bytes = await _ch.invokeMethod<Uint8List>('pickFile');
    if (bytes == null) return null;
    try {
      final m = jsonDecode(utf8.decode(gzip.decode(bytes)));
      if (m is Map && m['app'] == 'BRV Pos Sales' && m['tables'] is Map) return Map<String, dynamic>.from(m);
    } catch (_) {}
    throw const FormatException('This is not a BRV Pos Sales backup file.');
  }

  static String summary(Map<String, dynamic> b) {
    final t = b['tables'] as Map;
    int c(String k) => (t[k] as List?)?.length ?? 0;
    return '${b['business'] ?? ''}\nMade ${dateText(b['created'])}\n'
        '${c('sales')} sales · ${c('products')} products · ${c('users')} users · ${c('purchases')} purchases';
  }

  static Future<void> restore(Map<String, dynamic> b) async {
    final db = await Db.get();
    final t = Map<String, dynamic>.from(b['tables'] as Map);
    await db.transaction((tx) async {
      for (final name in Db.tables) {
        await tx.delete(name);
        for (final row in (t[name] as List? ?? const [])) {
          await tx.insert(name, Map<String, Object?>.from(row as Map));
        }
      }
    });
    await Settings.i.load();
  }
}
