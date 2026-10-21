import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'api.dart';

/// Prints a POS receipt on the handheld's built-in printer through Android
/// printing (the device's print service), 58 mm roll.
class Receipt {
  static String _m(double v) => v.toStringAsFixed(2);

  static Future<pw.Document> build(Sale s, {String shop = '', String phone = '', String email = '', String header = '', String footer = ''}) async {
    final doc = pw.Document();
    final base = pw.TextStyle(fontSize: 8);
    final bold = pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold);
    pw.Widget row(String a, String b, {pw.TextStyle? style}) => pw.Row(children: [
          pw.Expanded(child: pw.Text(a, style: style ?? base)),
          pw.Text(b, style: style ?? base),
        ]);
    doc.addPage(pw.Page(
      pageFormat: const PdfPageFormat(58 * PdfPageFormat.mm, double.infinity, marginAll: 2 * PdfPageFormat.mm),
      build: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Center(child: pw.Text(shop.isEmpty ? 'Soko Express Mtaani' : shop, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold))),
        if (phone.isNotEmpty) pw.Center(child: pw.Text('Tel: $phone', style: base)),
        if (email.isNotEmpty) pw.Center(child: pw.Text(email, style: base)),
        if (header.isNotEmpty) pw.Center(child: pw.Text(header, style: base, textAlign: pw.TextAlign.center)),
        pw.SizedBox(height: 4),
        pw.Center(child: pw.Text('Served by ${s.cashier}', style: base)),
        pw.Center(child: pw.Text(s.name, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold))),
        pw.Divider(thickness: 0.5),
        for (final l in s.lines) ...[
          row(l.name, _m(l.total), style: bold),
          pw.Text('  ${_q(l.qty)} x ${_m(l.price)}', style: base),
        ],
        pw.Divider(thickness: 0.5),
        row('TOTAL', 'KSh ${_m(s.amount)}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        if (s.tax > 0) row('of which tax', _m(s.tax)),
        pw.SizedBox(height: 3),
        for (final p in s.payments.where((p) => p.amount > 0)) ...[
          row(p.method, _m(p.amount)),
          if (p.ref.isNotEmpty) pw.Text('  Ref: ${p.ref}', style: base),
        ],
        if (s.change > 0) row('CHANGE', _m(s.change), style: bold),
        if (s.customer.isNotEmpty) ...[pw.SizedBox(height: 3), pw.Text('Customer: ${s.customer}', style: base)],
        pw.Divider(thickness: 0.5),
        if (footer.isNotEmpty) pw.Center(child: pw.Text(footer, style: base, textAlign: pw.TextAlign.center)),
        pw.Center(child: pw.Text(s.ref, style: base)),
        pw.Center(child: pw.Text(s.date, style: base)),
        pw.SizedBox(height: 2),
        pw.Center(child: pw.Text('Thank you!', style: bold)),
        pw.SizedBox(height: 12),
      ]),
    ));
    return doc;
  }

  static String _q(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  /// Opens Android printing with the receipt (choose the built-in printer once;
  /// Android remembers it).
  static Future<bool> print(Sale s, {String shop = '', String phone = '', String email = '', String header = '', String footer = ''}) async {
    final doc = await build(s, shop: shop, phone: phone, email: email, header: header, footer: footer);
    return Printing.layoutPdf(
      name: 'Receipt ${s.name}',
      format: const PdfPageFormat(58 * PdfPageFormat.mm, double.infinity, marginAll: 2 * PdfPageFormat.mm),
      onLayout: (_) async => doc.save(),
    );
  }
}
