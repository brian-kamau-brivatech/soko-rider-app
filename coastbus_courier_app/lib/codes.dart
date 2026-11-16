import 'db.dart';

/// What a scanned code means.
class Code {
  final String raw;
  final String kind; // waybill | manifest | unknown
  final String name;
  final int piece;
  const Code(this.raw, this.kind, this.name, this.piece);
  bool get isWaybill => kind == 'waybill';
}

/// Waybill sticker: "CB-MSA-01-00012/2" (piece 2) or "CB-MSA-01-00012". Receipt QR: tracking link ".../t/<token>".
/// Manifest slip QR: "MNF-MSA-01-0003".
Future<Code> parseCode(String raw) async {
  final c = raw.trim();
  final up = c.toUpperCase();
  if (up.startsWith('MNF-')) return Code(c, 'manifest', up, 0);
  final t = RegExp(r'/t/([A-Za-z0-9_\-]+)(?:#(\d+))?$').firstMatch(c);
  if (t != null) {
    final w = await Db.waybillByToken(t.group(1)!);
    if (w != null) return Code(c, 'waybill', '${w['name']}', int.tryParse(t.group(2) ?? '') ?? 1);
    return Code(c, 'token', t.group(1)!, int.tryParse(t.group(2) ?? '') ?? 1);
  }
  final m = RegExp(r'^([A-Z0-9][A-Z0-9\-]{3,}?)(?:/(\d+))?$').firstMatch(up);
  if (m != null) return Code(c, 'waybill', m.group(1)!, int.tryParse(m.group(2) ?? '') ?? 1);
  return Code(c, 'unknown', up, 0);
}

String pieceCode(String waybill, int piece, int pieces) => pieces > 1 ? '$waybill/$piece' : waybill;
