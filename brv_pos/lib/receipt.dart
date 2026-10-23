import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'kra.dart';
import 'sales.dart';
import 'settings.dart';
import 'ui.dart' show money, qtyText;

/// KRA receipt as one black-and-white image (58 mm = 384 dots, 80 mm = 576 dots).
/// Printed straight to the handheld printer when possible, or saved as a PDF.
class Receipt {
  static const _ch = MethodChannel('brv/print');
  static String lastMethod = '';

  static double get width => Settings.i.paperMm >= 80 ? 576 : 384;

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _date(DateTime t) => '${_two(t.day)}/${_two(t.month)}/${t.year}';
  static String _time(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  static Future<ui.Image?> _logo(double maxW) async {
    final path = Settings.i.logoPath;
    if (path.isEmpty) return null;
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final codec = await ui.instantiateImageCodec(await f.readAsBytes(), targetWidth: maxW.toInt());
      return (await codec.getNextFrame()).image;
    } catch (_) {
      return null;
    }
  }

  static TextPainter _tp(String text, double size, {bool bold = false, TextAlign align = TextAlign.left, required double max}) =>
      TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: const Color(0xFF000000), fontSize: size, fontWeight: bold ? FontWeight.w800 : FontWeight.w500, height: 1.2),
        ),
        textAlign: align,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: max);

  /// Builds the receipt image (PNG). [copy] = reprint: marked COPY, not official.
  static Future<Uint8List> image(Sale sale, {bool copy = false}) async {
    final s = Settings.i;
    final w = width;
    final k = w / 384; // scale fonts for 80 mm paper
    final pad = 8.0 * k;
    final inner = w - pad * 2;
    final ops = <(double, void Function(Canvas, double))>[];

    void gap(double hh) => ops.add((hh * k, (c, y) {}));
    void center(String t, double size, {bool bold = false}) {
      if (t.trim().isEmpty) return;
      final p = _tp(t, size * k, bold: bold, align: TextAlign.center, max: inner);
      ops.add((p.height, (c, y) => p.paint(c, Offset(pad + (inner - p.width) / 2, y))));
    }

    void row(String left, String right, double size, {bool bold = false}) {
      final r = _tp(right, size * k, bold: bold, max: inner);
      final l = _tp(left, size * k, bold: bold, max: inner - r.width - 10 * k);
      final hh = l.height > r.height ? l.height : r.height;
      ops.add((hh, (c, y) {
        l.paint(c, Offset(pad, y));
        r.paint(c, Offset(w - pad - r.width, y));
      }));
    }

    void left(String t, double size, {bool bold = false}) {
      final p = _tp(t, size * k, bold: bold, max: inner);
      ops.add((p.height, (c, y) => p.paint(c, Offset(pad, y))));
    }

    void cols(List<String> cells, List<double> widths, double size, {bool bold = false}) {
      final ps = <TextPainter>[];
      for (var i = 0; i < cells.length; i++) {
        ps.add(_tp(cells[i], size * k, bold: bold, max: inner * widths[i]));
      }
      final hh = ps.fold<double>(0, (a, p) => p.height > a ? p.height : a);
      ops.add((hh, (c, y) {
        var x = pad;
        for (var i = 0; i < ps.length; i++) {
          final colW = inner * widths[i];
          // first column left, others right-aligned
          final dx = i == 0 ? x : x + colW - ps[i].width;
          ps[i].paint(c, Offset(dx, y));
          x += colW;
        }
      }));
    }

    void dashes() => ops.add((14.0 * k, (c, y) {
          final paint = Paint()
            ..color = const Color(0xFF000000)
            ..strokeWidth = 2 * k;
          for (var x = pad; x < w - pad; x += 10 * k) {
            c.drawLine(Offset(x, y + 7 * k), Offset(x + 5 * k, y + 7 * k), paint);
          }
        }));

    // --- Header ---
    final logo = await _logo(inner * 0.7);
    if (logo != null) {
      final lw = logo.width.toDouble(), lh = logo.height.toDouble();
      ops.add((lh, (c, y) {
        c.drawImageRect(logo, Rect.fromLTWH(0, 0, lw, lh), Rect.fromLTWH((w - lw) / 2, y, lw, lh),
            Paint()..filterQuality = FilterQuality.high);
      }));
      gap(6);
    }
    center(s.shopName, 25, bold: true);
    center('PIN: ${s.tin}', 19, bold: true);
    if (s.address.isNotEmpty) center(s.address, 18);
    final contact = [if (s.phone.isNotEmpty) 'Tel: ${s.phone}', if (s.email.isNotEmpty) s.email].join('  ');
    if (contact.isNotEmpty) center(contact, 18);
    if (s.header.isNotEmpty) center(s.header, 18);
    gap(4);
    if (copy) {
      center('COPY', 46, bold: true);
    }
    center(sale.isCredit ? 'CREDIT NOTE' : 'TAX INVOICE', 24, bold: true);
    dashes();
    row('Receipt no.', sale.number, 19);
    row('Date', '${_date(sale.created)} ${_time(sale.created)}', 19);
    if (sale.row['cashier'] != null && '${sale.row['cashier']}'.isNotEmpty) row('Cashier', '${sale.row['cashier']}', 19);
    if (sale.customerTin.isNotEmpty) row('Customer PIN', sale.customerTin, 19);
    if (sale.customerName.isNotEmpty) row('Customer', sale.customerName, 19);
    if (sale.isCredit) {
      row('Original invoice', '${sale.row['org_invc_no']}', 19);
      final rsn = Kra.find(Kra.refundReasons, '${sale.row['rfd_rsn']}');
      if (rsn != null) row('Reason', rsn.name, 19);
    }
    dashes();

    // --- Items ---
    var discount = 0.0, before = 0.0;
    for (final l in sale.lines) {
      final qty = (l['qty'] as num).toDouble(), price = (l['price'] as num).toDouble();
      final tot = (l['tot'] as num).toDouble(), dc = (l['dc_amt'] as num?)?.toDouble() ?? 0;
      discount += dc;
      before += tot + dc;
      row('${l['name']}', '${money(tot + dc, symbol: false)} ${l['tax']}', 20, bold: true);
      left('  ${qtyText(qty)} x ${money(price, symbol: false)}', 18);
      if (dc > 0) row('  Discount ${(l['dc_rt'] as num).toStringAsFixed(0)}%', '-${money(dc, symbol: false)}', 18);
    }
    dashes();

    // --- Totals and tax table ---
    if (discount > 0) {
      row('Total before discount', money(before, symbol: false), 19);
      row('Discount', '-${money(discount, symbol: false)}', 19);
    }
    final p = sale.payload;
    cols(['Rate', 'Taxable', 'VAT'], [0.4, 0.3, 0.3], 17, bold: true);
    for (final t in ['A', 'B', 'C', 'D', 'E']) {
      final rate = Kra.rate(t);
      final taxbl = (p['taxblAmt$t'] as num?)?.toDouble() ?? 0;
      final taxAmt = (p['taxAmt$t'] as num?)?.toDouble() ?? 0;
      // KRA: print every rate above zero; zero rates only when an item used them.
      if (rate > 0 || taxbl != 0) {
        final label = '$t-${rate == 0 ? (t == 'A' ? 'Exempt' : t == 'C' ? '0%' : 'Non-VAT') : '${rate.toStringAsFixed(0)}%'}';
        cols([label, money(taxbl, symbol: false), money(taxAmt, symbol: false)], [0.4, 0.3, 0.3], 17);
      }
    }
    gap(4);
    row('Total VAT', money(sale.tax, symbol: false), 19);
    row('TOTAL', 'KSh ${money(sale.total, symbol: false)}', 28, bold: true);
    row(Kra.paymentName(sale.paymentCode), money(sale.tendered > 0 ? sale.tendered : sale.total, symbol: false), 19);
    if (sale.tendered > sale.total) row('Change', money(sale.tendered - sale.total, symbol: false), 19, bold: true);
    row('Items', '${sale.lines.length}', 19);
    if (copy) {
      gap(4);
      center('THIS IS NOT AN OFFICIAL RECEIPT', 24, bold: true);
    }
    dashes();

    // --- SCU information (KRA) ---
    final r = sale.row;
    final sdcId = '${r['sdc_id'] ?? ''}';
    final rcptNo = r['rcpt_no'];
    final when = parseEtims('${r['sdc_date'] ?? ''}') ?? sale.created;
    center('SCU INFORMATION', 20, bold: true);
    row('Date', _date(when), 18);
    row('Time', _time(when), 18);
    row('SCU ID', sdcId, 18);
    row('CU Invoice No.', '$sdcId/${rcptNo ?? ''}', 18);
    row('Receipt counter', '${rcptNo ?? ''}/${r['tot_rcpt_no'] ?? ''} ${sale.isCredit ? 'NC' : 'NS'}', 18);
    left('Internal data:', 18);
    left(hyphenate('${r['intrl_data'] ?? ''}'), 18, bold: true);
    left('Receipt signature:', 18);
    left(hyphenate('${r['rcpt_sign'] ?? ''}'), 18, bold: true);
    final url = receiptUrl(test: s.testMode, tin: s.tin, bhfId: s.bhfId, rcptSign: '${r['rcpt_sign'] ?? ''}');
    final qr = QrImage(QrCode.fromData(data: url, errorCorrectLevel: QrErrorCorrectLevel.L));
    final n = qr.moduleCount;
    final cell = ((200 * k) / n).floorToDouble().clamp(2.0, 10.0);
    final side = cell * n;
    gap(6);
    ops.add((side, (c, y) {
      final paint = Paint()..color = const Color(0xFF000000);
      final x0 = (w - side) / 2;
      for (var yy = 0; yy < n; yy++) {
        for (var xx = 0; xx < n; xx++) {
          if (qr.isDark(yy, xx)) c.drawRect(Rect.fromLTWH(x0 + xx * cell, y + yy * cell, cell, cell), paint);
        }
      }
    }));
    gap(6);
    dashes();
    if (s.footer.isNotEmpty) center(s.footer, 19, bold: true);
    center('Powered by BRV POS', 15);
    gap(70); // room to tear the paper

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

  /// Any printout (reports) from simple lines, same look as receipts.
  static Future<Uint8List> lines(List<PLine> lines, {bool logo = true}) async {
    final s = Settings.i;
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
            final p = _tp(l.a, l.size * k, bold: l.bold, align: TextAlign.center, max: inner);
            ops.add((p.height, (c, y) => p.paint(c, Offset(pad + (inner - p.width) / 2, y))));
          }
        case 'left':
          {
            final p = _tp(l.a, l.size * k, bold: l.bold, max: inner);
            ops.add((p.height, (c, y) => p.paint(c, Offset(pad, y))));
          }
        default: // row
          final r = _tp(l.b, l.size * k, bold: l.bold, max: inner);
          final lp = _tp(l.a, l.size * k, bold: l.bold, max: inner - r.width - 10 * k);
          final hh = lp.height > r.height ? lp.height : r.height;
          ops.add((hh, (c, y) {
            lp.paint(c, Offset(pad, y));
            r.paint(c, Offset(w - pad - r.width, y));
          }));
      }
    }

    if (logo) {
      final img = await _logo(inner * 0.6);
      if (img != null) {
        final lw = img.width.toDouble(), lh = img.height.toDouble();
        ops.add((lh, (c, y) {
          c.drawImageRect(img, Rect.fromLTWH(0, 0, lw, lh), Rect.fromLTWH((w - lw) / 2, y, lw, lh),
              Paint()..filterQuality = FilterQuality.high);
        }));
        ops.add((6 * k, (c, y) {}));
      }
    }
    for (final l in [
      PLine.center(s.shopName, size: 24, bold: true),
      PLine.center('PIN: ${s.tin}', size: 19, bold: true),
      if (s.address.isNotEmpty) PLine.center(s.address, size: 18),
      const PLine.gap(4),
      ...lines,
      const PLine.gap(4),
      const PLine.center('Powered by BRV POS', size: 15),
      const PLine.gap(70),
    ]) {
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

  /// Save any printout image as a PDF in Downloads/BRV POS.
  static Future<String?> pngPdf(Uint8List png, String name, {bool share = false}) async {
    try {
      return await _ch.invokeMethod<String>('savePdf', <String, dynamic>{
        'png': png,
        'name': name,
        'widthMm': Settings.i.paperMm >= 80 ? 80 : 58,
        'share': share,
      });
    } catch (_) {
      return null;
    }
  }

  /// Thermal printers print black or nothing: every dot black or white.
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
  // Printer choice: 'auto' | 'dialog' | a printer id from printerInfo
  // ---------------------------------------------------------------------------
  static Future<String> printerChoice() async {
    try {
      return (await SharedPreferences.getInstance()).getString('printer_choice') ?? 'auto';
    } catch (_) {
      return 'auto';
    }
  }

  static Future<void> setPrinterChoice(String id) async =>
      (await SharedPreferences.getInstance()).setString('printer_choice', id);

  static Future<bool> printPng(Uint8List png, String name) async {
    try {
      final how = await _ch.invokeMethod<String>('printImage', <String, dynamic>{
        'png': png,
        'name': name,
        'printer': await printerChoice(),
      });
      lastMethod = how ?? 'error';
      return lastMethod != 'error';
    } catch (_) {
      lastMethod = 'error';
      return false;
    }
  }

  /// Print a sale. Reprints are COPY receipts and are counted.
  static Future<bool> printSale(Sale sale, {bool copy = false}) async =>
      printPng(await image(sale, copy: copy), '${copy ? 'Copy ' : ''}${sale.number}');

  /// Save the receipt as a PDF in Downloads/BRV POS. Returns where it went, or null.
  static Future<String?> savePdf(Sale sale, {bool copy = false, bool share = false}) async {
    try {
      final png = await image(sale, copy: copy);
      return await _ch.invokeMethod<String>('savePdf', <String, dynamic>{
        'png': png,
        'name': '${sale.number}${copy ? '-COPY' : ''}',
        'widthMm': Settings.i.paperMm >= 80 ? 80 : 58,
        'share': share,
      });
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> printerInfo() async {
    try {
      return Map<String, dynamic>.from(await _ch.invokeMethod('printerInfo') as Map);
    } catch (e) {
      return {'error': '$e'};
    }
  }
}

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
