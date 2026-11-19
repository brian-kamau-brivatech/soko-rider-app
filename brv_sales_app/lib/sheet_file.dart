import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

/// Reads the first sheet of an Excel (.xlsx) file, or a CSV file, into rows of text.
/// No extra packages: an .xlsx is a zip of XML files, read here directly.
class SheetFile {
  static List<List<String>> read(Uint8List bytes) {
    if (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) return _xlsx(bytes);
    return csv(_text(bytes));
  }

  static String _text(Uint8List b) {
    var t = utf8.decode(b, allowMalformed: true);
    if (t.startsWith('﻿')) t = t.substring(1);
    return t;
  }

  // ---------------------------------------------------------------------------
  // CSV (comma or semicolon, quotes)
  // ---------------------------------------------------------------------------
  static List<List<String>> csv(String text) {
    final first = text.split('\n').first;
    final sep = ';'.allMatches(first).length > ','.allMatches(first).length ? ';' : ',';
    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell.write(c);
        }
      } else if (c == '"') {
        quoted = true;
      } else if (c == sep) {
        row.add(cell.toString());
        cell.clear();
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(cell.toString());
        cell.clear();
        rows.add(row);
        row = <String>[];
      } else {
        cell.write(c);
      }
    }
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      rows.add(row);
    }
    return rows.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();
  }

  // ---------------------------------------------------------------------------
  // XLSX
  // ---------------------------------------------------------------------------
  static Map<String, Uint8List> _unzip(Uint8List b) {
    final bd = ByteData.sublistView(b);
    // end of central directory: last "PK\x05\x06"
    var eocd = -1;
    for (var i = b.length - 22; i >= 0 && i >= b.length - 65557; i--) {
      if (bd.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('Not a valid Excel file.');
    final count = bd.getUint16(eocd + 10, Endian.little);
    var p = bd.getUint32(eocd + 16, Endian.little);
    final out = <String, Uint8List>{};
    for (var k = 0; k < count; k++) {
      if (bd.getUint32(p, Endian.little) != 0x02014b50) break;
      final method = bd.getUint16(p + 10, Endian.little);
      final csize = bd.getUint32(p + 20, Endian.little);
      final nameLen = bd.getUint16(p + 28, Endian.little);
      final extraLen = bd.getUint16(p + 30, Endian.little);
      final commentLen = bd.getUint16(p + 32, Endian.little);
      final local = bd.getUint32(p + 42, Endian.little);
      final name = utf8.decode(b.sublist(p + 46, p + 46 + nameLen));
      p += 46 + nameLen + extraLen + commentLen;
      if (!name.startsWith('xl/')) continue;
      final lName = bd.getUint16(local + 26, Endian.little);
      final lExtra = bd.getUint16(local + 28, Endian.little);
      final start = local + 30 + lName + lExtra;
      final data = b.sublist(start, start + csize);
      if (method == 0) {
        out[name] = data;
      } else if (method == 8) {
        out[name] = Uint8List.fromList(ZLibDecoder(raw: true).convert(data));
      }
    }
    return out;
  }

  static String _unescape(String s) => s
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)))
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  static String _texts(String xml) =>
      _unescape(RegExp(r'<t(?:\s[^>]*)?>([\s\S]*?)</t>').allMatches(xml).map((m) => m[1]!).join());

  static int _col(String ref) {
    var c = 0;
    for (final ch in ref.codeUnits) {
      if (ch < 65 || ch > 90) break;
      c = c * 26 + (ch - 64);
    }
    return c - 1;
  }

  static List<List<String>> _xlsx(Uint8List bytes) {
    final files = _unzip(bytes);
    final shared = <String>[];
    final ss = files['xl/sharedStrings.xml'];
    if (ss != null) {
      for (final m in RegExp(r'<si>([\s\S]*?)</si>').allMatches(utf8.decode(ss, allowMalformed: true))) {
        shared.add(_texts(m[1]!));
      }
    }
    // first sheet in workbook order
    var sheet = 'xl/worksheets/sheet1.xml';
    final wb = files['xl/workbook.xml'], rels = files['xl/_rels/workbook.xml.rels'];
    if (wb != null && rels != null) {
      final rid = RegExp(r'<sheet\b[^>]*r:id="([^"]+)"').firstMatch(utf8.decode(wb))?[1];
      if (rid != null) {
        for (final m in RegExp(r'<Relationship\b[^>]*>').allMatches(utf8.decode(rels))) {
          final tag = m[0]!;
          if (tag.contains('Id="$rid"')) {
            final target = RegExp(r'Target="([^"]+)"').firstMatch(tag)?[1] ?? '';
            sheet = target.startsWith('/') ? target.substring(1) : 'xl/$target';
          }
        }
      }
    }
    final data = files[sheet] ?? files.entries.firstWhere((e) => e.key.startsWith('xl/worksheets/sheet'), orElse: () => throw const FormatException('No sheet found in the Excel file.')).value;
    final xml = utf8.decode(data, allowMalformed: true);
    final rows = <List<String>>[];
    for (final r in RegExp(r'<row\b[^>]*>([\s\S]*?)</row>').allMatches(xml)) {
      final row = <String>[];
      for (final c in RegExp(r'<c\b([^>]*?)(?:/>|>([\s\S]*?)</c>)').allMatches(r[1]!)) {
        final attrs = c[1]!, body = c[2] ?? '';
        final ref = RegExp(r'\br="([A-Z]+)\d+"').firstMatch(attrs)?[1];
        final type = RegExp(r'\bt="([^"]+)"').firstMatch(attrs)?[1] ?? '';
        final v = RegExp(r'<v>([\s\S]*?)</v>').firstMatch(body)?[1];
        String text;
        if (type == 's') {
          final i = int.tryParse(v ?? '') ?? -1;
          text = i >= 0 && i < shared.length ? shared[i] : '';
        } else if (type == 'inlineStr') {
          text = _texts(body);
        } else {
          text = _unescape(v ?? '');
          // 150.0 -> 150, keep real decimals
          final num? x = num.tryParse(text);
          if (x != null && type != 'str') text = x == x.roundToDouble() ? x.toInt().toString() : x.toString();
        }
        final at = ref == null ? row.length : _col(ref);
        while (row.length < at) {
          row.add('');
        }
        if (at < row.length) {
          row[at] = text;
        } else {
          row.add(text);
        }
      }
      if (row.any((c) => c.trim().isNotEmpty)) rows.add(row);
    }
    return rows;
  }
}
