import 'package:flutter/services.dart';
import 'api.dart';

/// Prints a POS receipt on the handheld's built-in printer through Android
/// printing (native code in MainActivity), on a 58 mm roll.
class Receipt {
  static const _ch = MethodChannel('soko/alert');

  static String _m(double v) => v.toStringAsFixed(2);
  static String _q(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);
  static String _e(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  static String html(Sale s, {String shop = '', String phone = '', String email = '', String header = '', String footer = ''}) {
    String row(String a, String b, {bool bold = false}) =>
        '<tr${bold ? ' class="b"' : ''}><td>${_e(a)}</td><td class="r">${_e(b)}</td></tr>';
    final b = StringBuffer()
      ..write('<!doctype html><html><head><meta charset="utf-8"><style>'
          '@page{size:58mm auto;margin:0}'
          'body{margin:0;padding:2mm;width:54mm;font-family:monospace;font-size:11px;color:#000}'
          '.c{text-align:center}.r{text-align:right;white-space:nowrap}.b{font-weight:bold}'
          'table{width:100%;border-collapse:collapse}td{vertical-align:top;padding:1px 0}'
          'hr{border:0;border-top:1px dashed #000;margin:4px 0}'
          '.big{font-size:15px;font-weight:bold}.small{font-size:10px}'
          '</style></head><body>')
      ..write('<div class="c big">${_e(shop.isEmpty ? 'Soko Express Mtaani' : shop)}</div>');
    if (phone.isNotEmpty) b.write('<div class="c small">Tel: ${_e(phone)}</div>');
    if (email.isNotEmpty) b.write('<div class="c small">${_e(email)}</div>');
    if (header.isNotEmpty) b.write('<div class="c small">${_e(header)}</div>');
    b
      ..write('<div class="c small">Served by ${_e(s.cashier)}</div>')
      ..write('<div class="c big">${_e(s.name)}</div><hr><table>');
    for (final l in s.lines) {
      b
        ..write(row(l.name, _m(l.total), bold: true))
        ..write('<tr><td class="small">&nbsp;&nbsp;${_q(l.qty)} x ${_m(l.price)}</td><td></td></tr>');
    }
    b
      ..write('</table><hr><table>')
      ..write('<tr class="big"><td>TOTAL</td><td class="r">KSh ${_m(s.amount)}</td></tr>');
    if (s.tax > 0) b.write(row('of which tax', _m(s.tax)));
    for (final p in s.payments.where((p) => p.amount > 0)) {
      b.write(row(p.method, _m(p.amount)));
      if (p.ref.isNotEmpty) b.write('<tr><td class="small" colspan="2">&nbsp;&nbsp;Ref: ${_e(p.ref)}</td></tr>');
    }
    if (s.change > 0) b.write(row('CHANGE', _m(s.change), bold: true));
    b.write('</table>');
    if (s.customer.isNotEmpty) b.write('<div class="small">Customer: ${_e(s.customer)}</div>');
    b.write('<hr>');
    if (footer.isNotEmpty) b.write('<div class="c small">${_e(footer)}</div>');
    b
      ..write('<div class="c small">${_e(s.ref)}</div>')
      ..write('<div class="c small">${_e(s.date)}</div>')
      ..write('<div class="c b">Thank you!</div><br><br>')
      ..write('</body></html>');
    return b.toString();
  }

  /// Opens Android printing with the receipt. The first time, choose the
  /// built-in printer; Android remembers it.
  static Future<bool> print(Sale s, {String shop = '', String phone = '', String email = '', String header = '', String footer = ''}) async {
    try {
      await _ch.invokeMethod('printHtml', {
        'name': 'Receipt ${s.name}',
        'html': html(s, shop: shop, phone: phone, email: email, header: header, footer: footer),
      });
      return true;
    } catch (_) {
      return false;
    }
  }
}
