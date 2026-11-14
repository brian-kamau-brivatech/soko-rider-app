import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fmt.dart';
import 'settings.dart';

/// One line of a printout.
class PLine {
  final String kind; // center | left | row | dash | gap
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
}

/// Receipts and reports drawn as one black-and-white image (58 mm = 384 dots, 80 mm = 576 dots),
/// printed on the handheld's printer, a paired Bluetooth printer, or saved as PDF.
class Printer {
  static const _ch = MethodChannel('brv/print');
  static String lastMethod = '';

  static double get width => Settings.i.paperMm >= 80 ? 576 : 384;

  static TextPainter _tp(String text, double size, {bool bold = false, TextAlign align = TextAlign.left, required double max}) =>
      TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: const Color(0xFF000000), fontSize: size, fontWeight: bold ? FontWeight.w800 : FontWeight.w500, height: 1.2),
        ),
        textAlign: align,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: max);

  /// Header (business) + lines + footer as a PNG.
  static Future<Uint8List> image(List<PLine> body, {bool header = true}) async {
    final st = Settings.i;
    final w = width;
    final k = w / 384;
    final pad = 8.0 * k;
    final inner = w - pad * 2;
    final ops = <(double, void Function(Canvas, double))>[];
    void add(PLine l) {
      switch (l.kind) {
        case 'gap':
          ops.add((l.size * k, (c, y) {}));
        case 'dash':
          ops.add((14.0 * k, (c, y) {
            final paint = Paint()
              ..color = const Color(0xFF000000)
              ..strokeWidth = 2 * k;
            for (var x = pad; x < w - pad; x += 10 * k) {
              c.drawLine(Offset(x, y + 7 * k), Offset(x + 5 * k, y + 7 * k), paint);
            }
          }));
        case 'center':
          {
            if (l.a.trim().isEmpty) return;
            final p = _tp(l.a, l.size * k, bold: l.bold, align: TextAlign.center, max: inner);
            ops.add((p.height, (c, y) => p.paint(c, Offset(pad + (inner - p.width) / 2, y))));
          }
        case 'left':
          {
            final p = _tp(l.a, l.size * k, bold: l.bold, max: inner);
            ops.add((p.height, (c, y) => p.paint(c, Offset(pad, y))));
          }
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

    final all = <PLine>[
      if (header) ...[
        PLine.center(st.businessName, size: 25, bold: true),
        if (st.taxPin.isNotEmpty) PLine.center('PIN: ${st.taxPin}', size: 18, bold: true),
        if (st.address.isNotEmpty) PLine.center(st.address, size: 18),
        if (st.phone.isNotEmpty || st.email.isNotEmpty) PLine.center([if (st.phone.isNotEmpty) 'Tel: ${st.phone}', if (st.email.isNotEmpty) st.email].join('  '), size: 18),
        if (st.receiptHeader.isNotEmpty) PLine.center(st.receiptHeader, size: 18),
        const PLine.gap(4),
      ],
      ...body,
      const PLine.gap(4),
      const PLine.center('Powered by BRV Pos Sales', size: 15),
      const PLine.gap(70),
    ];
    for (final l in all) {
      add(l);
    }
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

  /// Sale or refund receipt.
  static List<PLine> saleLines(Map<String, Object?> sale, List<Map<String, Object?>> lines, List<Map<String, Object?>> pays, {bool copy = false}) {
    final refund = s(sale['kind']) == 'refund';
    final out = <PLine>[
      if (copy) const PLine.center('COPY', size: 40, bold: true),
      PLine.center(refund ? 'REFUND' : 'SALES RECEIPT', size: 23, bold: true),
      const PLine.dash(),
      PLine.row('Receipt', s(sale['number'])),
      PLine.row('Date', dateText(sale['date'])),
      if (s(sale['cashier']).isNotEmpty) PLine.row('Served by', s(sale['cashier'])),
      if (s(sale['customer']).isNotEmpty) PLine.row('Customer', s(sale['customer'])),
      const PLine.dash(),
    ];
    for (final l in lines) {
      final q = d(l['qty']).abs(), pr = d(l['price']), dc = d(l['discount']).abs(), tot = d(l['total']).abs();
      out.add(PLine.row(s(l['name']), money(tot + dc, symbol: false), size: 20, bold: true));
      out.add(PLine.left('  ${qty(q)} x ${money(pr, symbol: false)}', size: 18));
      if (dc > 0) out.add(PLine.row('  Discount', '-${money(dc, symbol: false)}', size: 18));
    }
    out.add(const PLine.dash());
    final tax = d(sale['tax']).abs();
    if (d(sale['discount']).abs() > 0) out.add(PLine.row('Discount', '-${money(d(sale['discount']).abs(), symbol: false)}'));
    if (tax > 0) {
      out.add(PLine.row('Amount before VAT', money(d(sale['net']).abs(), symbol: false)));
      out.add(PLine.row('VAT', money(tax, symbol: false)));
    }
    out.add(PLine.row('TOTAL', 'KSh ${money(d(sale['total']).abs(), symbol: false)}', size: 27, bold: true));
    for (final p in pays) {
      out.add(PLine.row(s(p['name']), money(d(p['amount']).abs(), symbol: false)));
    }
    if (d(sale['change']) > 0) out.add(PLine.row('Change', money(d(sale['change']), symbol: false), bold: true));
    if (copy) out.add(const PLine.center('REPRINT - NOT THE ORIGINAL', size: 18, bold: true));
    out.add(const PLine.dash());
    out.add(PLine.center(Settings.i.receiptFooter, size: 19, bold: true));
    return out;
  }

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

  // Printer choice: 'auto' | 'dialog' | a printer id from printerInfo
  static Future<String> choice() async {
    try {
      return (await SharedPreferences.getInstance()).getString('printer_choice') ?? 'auto';
    } catch (_) {
      return 'auto';
    }
  }

  static Future<void> setChoice(String id) async => (await SharedPreferences.getInstance()).setString('printer_choice', id);

  static Future<bool> printLines(List<PLine> body, String name, {bool header = true}) async {
    try {
      final png = await image(body, header: header);
      final how = await _ch.invokeMethod<String>('printImage', <String, dynamic>{'png': png, 'name': name, 'printer': await choice()});
      lastMethod = how ?? 'error';
      return lastMethod != 'error' && lastMethod != 'bt_failed';
    } catch (_) {
      lastMethod = 'error';
      return false;
    }
  }

  /// Saves (and optionally shares) as PDF in Downloads/BRV Pos Sales.
  static Future<String?> pdf(List<PLine> body, String name, {bool share = false}) async {
    try {
      final png = await image(body);
      return await _ch.invokeMethod<String>('savePdf', <String, dynamic>{
        'png': png, 'name': name, 'widthMm': Settings.i.paperMm >= 80 ? 80 : 58, 'share': share,
      });
    } catch (_) {
      return null;
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
