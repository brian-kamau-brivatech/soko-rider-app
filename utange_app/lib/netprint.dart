import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:http/http.dart' as http;
import 'api.dart';

/// Prints a black-and-white receipt image on a network receipt printer (ESC/POS, port 9100),
/// e.g. the Odoo kitchen / bar order printers or the Epson receipt printer set in Odoo.
class NetPrinter {
  /// Same as the Odoo POS with pos_escpos: the image goes to Odoo (/pos_escpos/print), which sends it to the
  /// printer at [ip] (reachable from the server, e.g. over Tailscale).
  static Future<bool> viaOdoo(String ip, Uint8List png) async {
    try {
      final r = await http
          .post(Uri.parse(Api.url('/pos_escpos/print')),
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
                if (Api.cookie.isNotEmpty) 'Cookie': 'session_id=${Api.cookie}',
              },
              body: jsonEncode({'img': base64Encode(png), 'ip': ip}))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return false;
      final body = jsonDecode(r.body);
      return body is Map && body['error'] == null;
    } catch (_) {
      return false;
    }
  }

  /// Sends by the printer's route: 'odoo' (pos_escpos) or straight to port 9100.
  static Future<bool> send(String ip, String via, Uint8List png) => via == 'odoo' ? viaOdoo(ip, png) : printPng(ip, png);

  static Future<bool> printPng(String ip, Uint8List png, {int port = 9100, bool cut = true}) async {
    Socket? s;
    try {
      final codec = await ui.instantiateImageCodec(png);
      final img = (await codec.getNextFrame()).image;
      final rgba = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      final data = raster(rgba, img.width, img.height, cut: cut);
      s = await Socket.connect(ip, port, timeout: const Duration(seconds: 6));
      s.add(data);
      await s.flush();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await s.close();
      return true;
    } catch (_) {
      try {
        s?.destroy();
      } catch (_) {}
      return false;
    }
  }

  /// RGBA pixels -> ESC/POS "GS v 0" raster in bands of 128 rows, then feed and cut.
  static Uint8List raster(Uint8List rgba, int w, int h, {bool cut = true}) {
    final bw = (w + 7) ~/ 8;
    final out = BytesBuilder();
    out.add([0x1B, 0x40]);
    var y0 = 0;
    while (y0 < h) {
      final band = (h - y0) < 128 ? (h - y0) : 128;
      out.add([0x1D, 0x76, 0x30, 0x00, bw & 0xFF, (bw >> 8) & 0xFF, band & 0xFF, (band >> 8) & 0xFF]);
      final rows = Uint8List(bw * band);
      for (var y = 0; y < band; y++) {
        for (var x = 0; x < w; x++) {
          final i = ((y0 + y) * w + x) * 4;
          final lum = (rgba[i] * 299 + rgba[i + 1] * 587 + rgba[i + 2] * 114) ~/ 1000;
          if (rgba[i + 3] > 127 && lum < 128) {
            rows[y * bw + (x >> 3)] |= (0x80 >> (x & 7));
          }
        }
      }
      out.add(rows);
      y0 += band;
    }
    out.add([0x1B, 0x64, 0x04]);
    if (cut) out.add([0x1D, 0x56, 0x42, 0x00]);
    return out.toBytes();
  }
}
