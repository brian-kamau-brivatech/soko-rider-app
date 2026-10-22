import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';

/// Prints POS receipts on the handheld's built-in printer.
///
/// The receipt (with the Soko logo) is drawn as one black-and-white image,
/// 384 dots wide (58 mm roll). It goes straight to the printer through the
/// printer service when the device has one the app knows (Sunmi or Nyx);
/// otherwise Android printing opens with the same image.
class Receipt {
  static const _ch = MethodChannel('soko/alert');
  static const width = 384.0;

  /// How the last receipt was printed: sunmi | nyx | dialog | error.
  static String lastMethod = '';

  static String _m(double v) => v.toStringAsFixed(2);
  static String _q(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  static ui.Image? _logo;
  static Future<ui.Image?> _loadLogo() async {
    if (_logo != null) return _logo;
    try {
      final data = await rootBundle.load('assets/logo.png');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(), targetWidth: 320);
      _logo = (await codec.getNextFrame()).image;
    } catch (_) {}
    return _logo;
  }

  /// Direct printing on (default) or always show Android's print preview.
  static Future<bool> directEnabled() async {
    try {
      return (await SharedPreferences.getInstance()).getBool('print_direct') ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setDirect(bool on) async => (await SharedPreferences.getInstance()).setBool('print_direct', on);

  // ---------------------------------------------------------------------------
  // Drawing
  // ---------------------------------------------------------------------------
  static TextPainter _tp(String text, double size, {bool bold = false, TextAlign align = TextAlign.left, double max = width - 16}) {
    final p = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: const Color(0xFF000000), fontSize: size, fontWeight: bold ? FontWeight.w800 : FontWeight.w500, height: 1.2),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: max);
    return p;
  }

  /// Builds the receipt image as PNG bytes.
  static Future<Uint8List> image(Sale s, {String shop = '', String phone = '', String email = '', String header = '', String footer = ''}) async {
    const pad = 8.0;
    const inner = width - pad * 2;
    final ops = <(double, void Function(Canvas, double))>[];

    void gap(double h) => ops.add((h, (c, y) {}));
    void center(String t, double size, {bool bold = false}) {
      if (t.trim().isEmpty) return;
      final p = _tp(t, size, bold: bold, align: TextAlign.center, max: inner);
      ops.add((p.height, (c, y) => p.paint(c, Offset(pad + (inner - p.width) / 2, y))));
    }

    void row(String left, String right, double size, {bool bold = false, bool boldLeft = false}) {
      final r = _tp(right, size, bold: bold);
      final l = _tp(left, size, bold: bold || boldLeft, max: inner - r.width - 10);
      final h = l.height > r.height ? l.height : r.height;
      ops.add((h, (c, y) {
        l.paint(c, Offset(pad, y));
        r.paint(c, Offset(width - pad - r.width, y));
      }));
    }

    void left(String t, double size) {
      final p = _tp(t, size, max: inner);
      ops.add((p.height, (c, y) => p.paint(c, Offset(pad, y))));
    }

    void dashes() => ops.add((14.0, (c, y) {
          final paint = Paint()
            ..color = const Color(0xFF000000)
            ..strokeWidth = 2;
          for (var x = pad; x < width - pad; x += 10) {
            c.drawLine(Offset(x, y + 7), Offset(x + 5, y + 7), paint);
          }
        }));

    final logo = await _loadLogo();
    if (logo != null) {
      final h = logo.height * (320 / logo.width);
      ops.add((h, (c, y) {
        c.drawImageRect(logo, Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
            Rect.fromLTWH((width - 320) / 2, y, 320, h), Paint()..filterQuality = FilterQuality.high);
      }));
      gap(6);
    } else {
      center(shop.isEmpty ? 'Soko Express Mtaani' : shop, 28, bold: true);
    }
    if (phone.isNotEmpty) center('Tel: $phone', 19);
    if (email.isNotEmpty) center(email, 19);
    if (header.isNotEmpty) center(header, 19);
    center('Served by ${s.cashier}', 19);
    gap(4);
    center(s.name, 27, bold: true);
    dashes();
    for (final l in s.lines) {
      row(l.name, _m(l.total), 22, boldLeft: true);
      left('   ${_q(l.qty)} x ${_m(l.price)}', 19);
      gap(3);
    }
    dashes();
    row('TOTAL', 'KSh ${_m(s.amount)}', 28, bold: true);
    if (s.tax > 0) row('of which tax', _m(s.tax), 19);
    for (final p in s.payments.where((p) => p.amount > 0)) {
      row(p.method, _m(p.amount), 21);
      if (p.ref.isNotEmpty) left('   Ref: ${p.ref}', 19);
    }
    if (s.change > 0) row('CHANGE', _m(s.change), 23, bold: true);
    if (s.customer.isNotEmpty) {
      gap(4);
      left('Customer: ${s.customer}', 20);
    }
    dashes();
    if (footer.isNotEmpty) center(footer, 19);
    center(s.ref, 19);
    center(s.date, 19);
    gap(4);
    center('Thank you!', 24, bold: true);
    gap(70); // room to tear the paper

    final total = ops.fold<double>(0, (a, o) => a + o.$1).ceil().toDouble();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, Rect.fromLTWH(0, 0, width, total));
    canvas.drawRect(Rect.fromLTWH(0, 0, width, total), Paint()..color = const Color(0xFFFFFFFF));
    var y = 0.0;
    for (final o in ops) {
      o.$2(canvas, y);
      y += o.$1;
    }
    final img = await rec.endRecording().toImage(width.toInt(), total.toInt());
    return _blackAndWhite(img);
  }

  /// Thermal printers print black or nothing: make every dot black or white.
  static Future<Uint8List> _blackAndWhite(ui.Image img) async {
    final raw = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    for (var i = 0; i < raw.length; i += 4) {
      final lum = 0.299 * raw[i] + 0.587 * raw[i + 1] + 0.114 * raw[i + 2];
      final v = (raw[i + 3] > 40 && lum < 175) ? 0 : 255;
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

  // ---------------------------------------------------------------------------
  // Printing
  // ---------------------------------------------------------------------------
  static Future<bool> print(Sale s, {String shop = '', String phone = '', String email = '', String header = '', String footer = ''}) async {
    try {
      final png = await image(s, shop: shop, phone: phone, email: email, header: header, footer: footer);
      final direct = await directEnabled();
      final how = await _ch.invokeMethod<String>('printImage', <String, dynamic>{
        'png': png,
        'name': 'Receipt ${s.name}',
        'direct': direct,
      });
      lastMethod = how ?? 'error';
      return lastMethod != 'error';
    } catch (_) {
      lastMethod = 'error';
      return false;
    }
  }

  /// What printer services this handheld has (Settings > Printer check).
  static Future<Map<String, dynamic>> printerInfo() async {
    try {
      final r = await _ch.invokeMethod('printerInfo');
      return Map<String, dynamic>.from(r as Map);
    } catch (e) {
      return {'error': '$e'};
    }
  }
}
