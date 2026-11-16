import 'dart:math';

String money(num v, {bool symbol = true}) {
  final neg = v < 0;
  final s = v.abs().toStringAsFixed(v.abs() % 1 == 0 ? 0 : 2);
  final parts = s.split('.');
  final b = StringBuffer();
  final ip = parts[0];
  for (var i = 0; i < ip.length; i++) {
    if (i > 0 && (ip.length - i) % 3 == 0) b.write(',');
    b.write(ip[i]);
  }
  final out = parts.length > 1 ? '$b.${parts[1]}' : '$b';
  return '${neg ? '-' : ''}${symbol ? 'KES ' : ''}$out';
}

String kg(num v) => '${v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(2)} kg';

double d(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
int n(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0);
String s(Object? v) => v == null || v == false ? '' : '$v';

/// UTC timestamp as Odoo stores it.
String utcNow() => odooTime(DateTime.now());
String odooTime(DateTime t) {
  final u = t.toUtc();
  String p(int x) => x.toString().padLeft(2, '0');
  return '${u.year}-${p(u.month)}-${p(u.day)} ${p(u.hour)}:${p(u.minute)}:${p(u.second)}';
}

DateTime? fromOdoo(String? v) {
  if (v == null || v.isEmpty) return null;
  return DateTime.tryParse('${v.replaceFirst(' ', 'T')}Z')?.toLocal();
}

const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String dt(DateTime? t, {bool time = true}) {
  if (t == null) return '';
  String p(int x) => x.toString().padLeft(2, '0');
  final day = '${p(t.day)}-${_mon[t.month - 1]}-${t.year}';
  return time ? '$day ${p(t.hour)}:${p(t.minute)}' : day;
}

String dtOdoo(String? v, {bool time = true}) => dt(fromOdoo(v), time: time);

final _rnd = Random.secure();
String uuid4() {
  final b = List<int>.generate(16, (_) => _rnd.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

String randomToken(int len) {
  const a = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return List.generate(len, (_) => a[_rnd.nextInt(a.length)]).join();
}

String otp6() => _rnd.nextInt(1000000).toString().padLeft(6, '0');

/// Kenyan numbers to +2547...; others trimmed.
String normPhone(String v) {
  final p = v.replaceAll(RegExp(r'[^\d+]'), '');
  if (p.startsWith('+')) return p;
  if (p.startsWith('254') && p.length == 12) return '+$p';
  if (p.startsWith('0') && p.length == 10) return '+254${p.substring(1)}';
  if (p.length == 9 && (p.startsWith('7') || p.startsWith('1'))) return '+254$p';
  return p;
}

bool phoneOk(String v) => RegExp(r'^\+254[17]\d{8}$').hasMatch(normPhone(v)) || RegExp(r'^\+\d{9,14}$').hasMatch(normPhone(v));

String maskPhone(String p) => p.length > 6 ? '${p.substring(0, p.length - 6)}***${p.substring(p.length - 3)}' : p;
String localPhone(String p) => p.startsWith('+254') ? '0${p.substring(4)}' : p;
