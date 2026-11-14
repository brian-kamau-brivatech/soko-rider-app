/// Small helpers for reading database rows and showing numbers.
library;

double d(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0;
int n(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
String s(Object? v) => v == null ? '' : '$v';

double r2(double v) => (v * 100).roundToDouble() / 100;

String money(double v, {bool symbol = true}) {
  final neg = v < -0.004;
  final str = v.abs().toStringAsFixed(2);
  final parts = str.split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return '${neg ? '-' : ''}${symbol ? 'KSh ' : ''}$whole.${parts[1]}';
}

/// 12,450 / 1.2K / 3.4M for dashboard tiles.
String short(double v) {
  final a = v.abs();
  final sign = v < 0 ? '-' : '';
  if (a >= 1000000) return '$sign${(a / 1000000).toStringAsFixed(a >= 10000000 ? 0 : 1)}M';
  if (a >= 10000) return '$sign${(a / 1000).toStringAsFixed(a >= 100000 ? 0 : 1)}K';
  return '$sign${a.toStringAsFixed(0).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',')}';
}

String qty(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

String two(int v) => v.toString().padLeft(2, '0');

String dayKey(DateTime t) => '${t.year}-${two(t.month)}-${two(t.day)}';

String nowIso() => DateTime.now().toIso8601String();

String dateText(Object? iso, {bool time = true}) {
  final t = DateTime.tryParse(s(iso));
  if (t == null) return '';
  final dd = '${two(t.day)}/${two(t.month)}/${t.year}';
  return time ? '$dd ${two(t.hour)}:${two(t.minute)}' : dd;
}

const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

String initials(String name) {
  final p = name.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
  if (p.isEmpty) return '?';
  if (p.length == 1) return p[0].substring(0, p[0].length >= 2 ? 2 : 1).toUpperCase();
  return (p[0][0] + p[1][0]).toUpperCase();
}
