import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:barcode/barcode.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'master.dart';

/// One line of a printout.
class PLine {
  final String kind; // center | left | row | dash | gap | barcode | qr | big | sign | logo
  final String a;
  final String b;
  final double size;
  final bool bold;
  const PLine.center(this.a, {this.size = 19, this.bold = false})
      : kind = 'center',
        b = '';
  const PLine.left(this.a, {this.size = 19, this.bold = false})
      : kind = 'left',
        b = '';
  const PLine.row(this.a, this.b, {this.size = 19, this.bold = false}) : kind = 'row';
  const PLine.dash()
      : kind = 'dash',
        a = '',
        b = '',
        size = 0,
        bold = false;
  const PLine.gap(this.size)
      : kind = 'gap',
        a = '',
        b = '',
        bold = false;
  const PLine.barcode(this.a, {this.size = 70})
      : kind = 'barcode',
        b = '',
        bold = false;
  const PLine.qr(this.a, {this.size = 200})
      : kind = 'qr',
        b = '',
        bold = false;
  /// White text on a black band (destination on stickers, alerts).
  const PLine.big(this.a, {this.size = 40})
      : kind = 'big',
        b = '',
        bold = true;
  /// Signature line with a caption.
  const PLine.sign(this.a)
      : kind = 'sign',
        b = '',
        size = 18,
        bold = false;
  const PLine.logo()
      : kind = 'logo',
        a = '',
        b = '',
        size = 0,
        bold = false;
}

/// Printouts drawn as one black-and-white image (58 mm = 384 dots, 80 mm = 576), sent to the handheld's printer,
/// a paired Bluetooth printer, or Android printing.
class Printer {
  static const _ch = MethodChannel('brv/print');
  static String lastMethod = '';
  static int paperMm = 58;

  static Future<void> load() async {
    try {
      paperMm = (await SharedPreferences.getInstance()).getInt('paper_mm') ?? 58;
    } catch (_) {}
  }

  static Future<void> setPaper(int mm) async {
    paperMm = mm;
    (await SharedPreferences.getInstance()).setInt('paper_mm', mm);
  }

  static double get width => paperMm >= 80 ? 576 : 384;

  static TextPainter _tp(String text, double size, {bool bold = false, TextAlign align = TextAlign.left, required double max, Color color = const Color(0xFF000000)}) =>
      TextPainter(
        text: TextSpan(text: text, style: TextStyle(color: color, fontSize: size, fontWeight: bold ? FontWeight.w800 : FontWeight.w500, height: 1.2)),
        textAlign: align,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: max);

  static Future<Uint8List> image(List<PLine> lines) async {
    final w = width;
    final k = w / 384;
    final pad = 8.0 * k;
    final inner = w - pad * 2;
    final ops = <(double, void Function(Canvas, double))>[];
    final black = Paint()..color = const Color(0xFF000000);
    ui.Image? logo;
    final logoB64 = '${Master.i.company['logo'] ?? ''}';
    if (lines.any((l) => l.kind == 'logo') && logoB64.isNotEmpty) {
      try {
        logo = (await (await ui.instantiateImageCodec(base64Decode(logoB64))).getNextFrame()).image;
      } catch (_) {}
    }
    for (final l in lines) {
      switch (l.kind) {
        case 'gap':
          ops.add((l.size * k, (c, y) {}));
        case 'logo':
          if (logo != null) {
            final img = logo;
            var lw = inner * 0.55, lh = lw * img.height / img.width;
            if (lh > 120 * k) {
              lh = 120 * k;
              lw = lh * img.width / img.height;
            }
            ops.add((lh + 6 * k, (c, y) {
              c.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), Rect.fromLTWH((w - lw) / 2, y, lw, lh),
                  Paint()..filterQuality = FilterQuality.high);
            }));
          }
        case 'dash':
          ops.add((14.0 * k, (c, y) {
            final p = Paint()
              ..color = const Color(0xFF000000)
              ..strokeWidth = 2 * k;
            for (var x = pad; x < w - pad; x += 10 * k) {
              c.drawLine(Offset(x, y + 7 * k), Offset(x + 5 * k, y + 7 * k), p);
            }
          }));
        case 'center':
          if (l.a.trim().isNotEmpty) {
            final p = _tp(l.a, l.size * k, bold: l.bold, align: TextAlign.center, max: inner);
            ops.add((p.height, (c, y) => p.paint(c, Offset(pad + (inner - p.width) / 2, y))));
          }
        case 'left':
          {
            final p = _tp(l.a, l.size * k, bold: l.bold, max: inner);
            ops.add((p.height, (c, y) => p.paint(c, Offset(pad, y))));
          }
        case 'big':
          {
            final p = _tp(l.a, l.size * k, bold: true, align: TextAlign.center, max: inner - 12 * k, color: const Color(0xFFFFFFFF));
            final hh = p.height + 14 * k;
            ops.add((hh + 6 * k, (c, y) {
              c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(pad, y, inner, hh), Radius.circular(8 * k)), black);
              p.paint(c, Offset(pad + (inner - p.width) / 2, y + 7 * k));
            }));
          }
        case 'sign':
          {
            final p = _tp(l.a, l.size * k, max: inner);
            ops.add((p.height + 46 * k, (c, y) {
              p.paint(c, Offset(pad, y));
              c.drawLine(Offset(pad, y + p.height + 38 * k), Offset(w - pad, y + p.height + 38 * k), Paint()..strokeWidth = 1.5 * k);
            }));
          }
        case 'barcode':
          try {
            final bc = Barcode.code128();
            final bw = inner;
            final bh = l.size * k;
            final els = bc.make(l.a, width: bw, height: bh, drawText: false).toList();
            ops.add((bh + 4 * k, (c, y) {
              for (final e in els) {
                if (e is BarcodeBar && e.black) c.drawRect(Rect.fromLTWH(pad + e.left, y + e.top, e.width, e.height), black);
              }
            }));
          } catch (_) {}
        case 'qr':
          try {
            final sz = (l.size * k).clamp(80.0, inner).toDouble();
            final els = Barcode.qrCode(errorCorrectLevel: BarcodeQRCorrectionLevel.medium).make(l.a, width: sz, height: sz).toList();
            final x0 = (w - sz) / 2;
            ops.add((sz + 6 * k, (c, y) {
              for (final e in els) {
                if (e is BarcodeBar && e.black) c.drawRect(Rect.fromLTWH(x0 + e.left, y + e.top, e.width + 0.5, e.height + 0.5), black);
              }
            }));
          } catch (_) {}
        default:
          {
            final r = _tp(l.b, l.size * k, bold: l.bold, max: inner);
            final lp = _tp(l.a, l.size * k, bold: l.bold, max: inner - r.width - 10 * k);
            final hh = lp.height > r.height ? lp.height : r.height;
            ops.add((hh, (c, y) {
              lp.paint(c, Offset(pad, y));
              r.paint(c, Offset(w - pad - r.width, y));
            }));
          }
      }
    }
    ops.add((60 * k, (c, y) {})); // tear-off feed
    final total = ops.fold<double>(0, (a, o) => a + o.$1).ceil().toDouble();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w, total));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, total), Paint()..color = const Color(0xFFFFFFFF));
    var y = 0.0;
    for (final o in ops) {
      o.$2(canvas, y);
      y += o.$1;
    }
    final img = await rec.endRecording().toImage(w.toInt(), total.toInt());
    return _blackAndWhite(img);
  }

  static Future<Uint8List> _blackAndWhite(ui.Image img) async {
    final raw = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    for (var i = 0; i < raw.length; i += 4) {
      final lum = 0.299 * raw[i] + 0.587 * raw[i + 1] + 0.114 * raw[i + 2];
      final v = (raw[i + 3] > 40 && lum < 160) ? 0 : 255;
      raw[i] = v;
      raw[i + 1] = v;
      raw[i + 2] = v;
      raw[i + 3] = 255;
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(raw, img.width, img.height, ui.PixelFormat.rgba8888, done.complete);
    final bw = await done.future;
    return (await bw.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  }

  static Future<String> choice() async {
    try {
      return (await SharedPreferences.getInstance()).getString('printer_choice') ?? 'auto';
    } catch (_) {
      return 'auto';
    }
  }

  static Future<void> setChoice(String id) async => (await SharedPreferences.getInstance()).setString('printer_choice', id);

  static Future<bool> print(List<PLine> lines, String name) async {
    try {
      final png = await image(lines);
      final how = await _ch.invokeMethod<String>('printImage', <String, dynamic>{'png': png, 'name': name, 'printer': await choice()});
      lastMethod = how ?? 'error';
      return lastMethod != 'error' && lastMethod != 'bt_failed';
    } catch (_) {
      lastMethod = 'error';
      return false;
    }
  }

  static Future<Map<String, dynamic>> info() async {
    try {
      return Map<String, dynamic>.from(await _ch.invokeMethod('printerInfo') as Map);
    } catch (e) {
      return {'error': '$e'};
    }
  }
}
