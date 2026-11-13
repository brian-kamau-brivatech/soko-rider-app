import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'netprint.dart';
import 'store.dart';

/// Prints POS receipts on the handheld's built-in printer.
///
/// The receipt (with the company logo from Odoo) is drawn as one black-and-white image,
/// 384 dots wide (58 mm roll). It goes straight to the printer through the
/// printer service when the device has one the app knows (Sunmi or Nyx);
/// otherwise Android printing opens with the same image.
class Receipt {
  static const _ch = MethodChannel('brv/print');
  static const width = 384.0;

  /// How the last receipt was printed: sunmi | nyx | dialog | error.
  static String lastMethod = '';

  static String _m(double v) => v.toStringAsFixed(2);
  static String _q(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  static ui.Image? _logo;
  static int _logoLen = -1;
  static Future<ui.Image?> _loadLogo() async {
    final bytes = Store.i.logo;
    if (bytes == null || bytes.isEmpty) return null;
    if (_logo != null && _logoLen == bytes.length) return _logo;
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 300);
      _logo = (await codec.getNextFrame()).image;
      _logoLen = bytes.length;
    } catch (_) {}
    return _logo;
  }

  /// Which printer to use: 'auto' (first one that prints without a preview),
  /// 'dialog' (always Android's print screen) or a printer id from [printerInfo].
  static Future<String> printerChoice() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString('printer_choice') ?? ((p.getBool('print_direct') ?? true) ? 'auto' : 'dialog');
    } catch (_) {
      return 'auto';
    }
  }

  static Future<void> setPrinterChoice(String id) async =>
      (await SharedPreferences.getInstance()).setString('printer_choice', id);

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
  static Future<Uint8List> image(Sale s, {String shop = '', String phone = '', String email = '', String header = '', String footer = '', String vat = '', String address = ''}) async {
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
      final lw = logo.width > 300 ? 300.0 : logo.width.toDouble();
      final h = logo.height * (lw / logo.width);
      ops.add((h, (c, y) {
        c.drawImageRect(logo, Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
            Rect.fromLTWH((width - lw) / 2, y, lw, h), Paint()..filterQuality = FilterQuality.high);
      }));
      gap(6);
    }
    center(shop, 23, bold: true);
    if (address.isNotEmpty) center(address, 19);
    if (vat.isNotEmpty) center('PIN: $vat', 19);
    if (phone.isNotEmpty) center('Tel: $phone', 19);
    if (email.isNotEmpty) center(email, 19);
    if (header.isNotEmpty) center(header, 19);
    center('Served by ${s.cashier}', 19);
    gap(4);
    center(s.name, 25, bold: true);
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
  static Future<bool> print(Sale s, {String shop = '', String phone = '', String email = '', String header = '', String footer = '', String vat = '', String address = ''}) async {
    try {
      final png = await image(s, shop: shop, phone: phone, email: email, header: header, footer: footer, vat: vat, address: address);
      final choice = await printerChoice();
      if (choice.startsWith('odoo:')) {
        final ok = await NetPrinter.viaOdoo(choice.substring(5), png);
        lastMethod = ok ? 'network' : 'net_failed';
        return ok;
      }
      if (choice.startsWith('net:')) {
        final ok = await NetPrinter.printPng(choice.substring(4), png);
        lastMethod = ok ? 'network' : 'net_failed';
        return ok;
      }
      final how = await _ch.invokeMethod<String>('printImage', <String, dynamic>{
        'png': png,
        'name': 'Receipt ${s.name}',
        'printer': choice,
      });
      lastMethod = how ?? 'error';
      return lastMethod != 'error' && lastMethod != 'bt_failed' && lastMethod != 'net_failed';
    } catch (_) {
      lastMethod = 'error';
      return false;
    }
  }

  /// Kitchen / bar order ticket (big print, no prices) for the Odoo preparation printers.
  static Future<Uint8List> ticket({required String printer, required String order, required String cashier,
      required List<(double, String)> lines, String note = ''}) async {
    const pad = 8.0;
    const inner = width - pad * 2;
    final ops = <(double, void Function(Canvas, double))>[];
    void gap(double h) => ops.add((h, (c, y) {}));
    void center(String t, double size, {bool bold = false}) {
      final p = _tp(t, size, bold: bold, align: TextAlign.center, max: inner);
      ops.add((p.height, (c, y) => p.paint(c, Offset(pad + (inner - p.width) / 2, y))));
    }
    void left(String t, double size, {bool bold = false}) {
      final p = _tp(t, size, bold: bold, max: inner);
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
    center(printer.toUpperCase(), 24, bold: true);
    center(order, 30, bold: true);
    final now = DateTime.now();
    center('${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} · $cashier', 20);
    dashes();
    for (final l in lines) {
      left('${_q(l.$1)} x ${l.$2}', 30, bold: true);
      gap(4);
    }
    if (note.isNotEmpty) {
      dashes();
      left(note, 22);
    }
    gap(40);
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

  /// Sends order tickets to the Odoo kitchen / bar printers whose categories are in the sale.
  /// Returns the names of printers that did not answer.
  static Future<List<String>> printKitchen(Sale s, PosSetup st, List<(double, String, List<int>)> cart) async {
    final failed = <String>[];
    for (final pr in st.kitchenPrinters) {
      final lines = <(double, String)>[
        for (final c in cart)
          if (pr.categIds.isEmpty || c.$3.any(pr.categIds.contains)) (c.$1, c.$2),
      ];
      if (lines.isEmpty) continue;
      try {
        final png = await ticket(printer: pr.name, order: s.name, cashier: s.cashier, lines: lines,
            note: s.customer.isEmpty ? '' : 'Customer: ${s.customer}');
        if (!await NetPrinter.send(pr.ip, pr.via, png)) failed.add(pr.name);
      } catch (_) {
        failed.add(pr.name);
      }
    }
    return failed;
  }

  /// The bill: on the Odoo bill printer when the POS has one (pos_escpos) and the handheld is on "Automatic",
  /// otherwise on the printer chosen in Settings.
  static Future<bool> printSale(Sale s, PosSetup? st) async {
    final choice = await printerChoice();
    if (choice == 'auto' && st != null && st.receiptPrinterIp.isNotEmpty) {
      try {
        final png = await image(s, shop: st.shopName, phone: st.shopPhone, email: st.shopEmail, header: st.header,
            footer: st.footer, vat: st.shopVat, address: st.shopAddress);
        final ok = await NetPrinter.send(st.receiptPrinterIp, st.receiptPrinterVia, png);
        lastMethod = ok ? 'network' : 'net_failed';
        if (ok) return true;
      } catch (_) {}
    }
    return _printSaleHere(s, st);
  }

  static Future<bool> _printSaleHere(Sale s, PosSetup? st) => print(s,
      shop: st?.shopName ?? Store.i.companyName,
      phone: st?.shopPhone ?? '',
      email: st?.shopEmail ?? '',
      header: st?.header ?? '',
      footer: st?.footer ?? '',
      vat: st?.shopVat ?? '',
      address: st?.shopAddress ?? '');

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
