import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'fmt.dart';

/// BRV Integrated Systems colours: navy (the "dark" of the design) and gold.
class C {
  static const ink = Color(0xFF0A2348); // BRV navy
  static const ink2 = Color(0xFF1B3F73);
  static const gold = Color(0xFFC38B2C);
  static const goldLight = Color(0xFFF8EEDB);
  static const bg = Color(0xFFF4F5F8);
  static const card = Colors.white;
  static const soft = Color(0xFFF0F1F5);
  static const line = Color(0xFFE5E7ED);
  static const text = Color(0xFF111827);
  static const muted = Color(0xFF6B7280);
  static const lilac = Color(0xFFBDBBF7);
  static const pink = Color(0xFFF2A7B5);
  static const green = Color(0xFF0E8A55);
  static const greenLight = Color(0xFFE3F5EC);
  static const red = Color(0xFFB4232A);
  static const redLight = Color(0xFFFDECEC);
  static const amber = Color(0xFFA95C00);
  static const amberLight = Color(0xFFFFF3DF);
}

TextStyle h(double size, {FontWeight w = FontWeight.w800, Color color = C.text}) =>
    TextStyle(fontSize: size, fontWeight: w, color: color, letterSpacing: -0.3);

const muted = TextStyle(color: C.muted, fontSize: 13);

BoxDecoration box({Color color = C.card, double r = 18, bool border = true}) => BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(r),
      border: border ? Border.all(color: C.line) : null,
    );

ThemeData appTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: C.ink, primary: C.ink, secondary: C.gold, surface: Colors.white);
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: C.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: C.bg,
      foregroundColor: C.text,
      surfaceTintColor: C.bg,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(color: C.text, fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.4),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.ink,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: C.ink,
        minimumSize: const Size(0, 50),
        side: const BorderSide(color: C.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.ink, width: 1.5)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: C.ink, foregroundColor: Colors.white),
    dividerTheme: const DividerThemeData(color: C.line, space: 1),
    listTileTheme: const ListTileThemeData(iconColor: C.ink),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'Yes', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: danger ? FilledButton.styleFrom(backgroundColor: C.red, minimumSize: const Size(0, 42)) : FilledButton.styleFrom(minimumSize: const Size(0, 42)),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}

/// Asks for one value (text or number).
Future<String?> ask(BuildContext context, String title, {String initial = '', String label = '', bool number = false, String? hint}) async {
  final c = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        decoration: InputDecoration(labelText: label.isEmpty ? null : label, hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), style: FilledButton.styleFrom(minimumSize: const Size(0, 42)), child: const Text('OK')),
      ],
    ),
  );
  return r;
}

double? numIn(String? v) => v == null ? null : double.tryParse(v.trim().replaceAll(',', ''));

class Empty extends StatelessWidget {
  final IconData icon;
  final String text;
  const Empty(this.icon, this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        child: Column(children: [
          Icon(icon, size: 46, color: C.muted),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: C.muted, fontSize: 15)),
        ]),
      );
}

class Pill extends StatelessWidget {
  final String text;
  final Color fg;
  final Color bg;
  const Pill(this.text, {super.key, this.fg = C.muted, this.bg = C.soft});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: h(11.5, color: fg, w: FontWeight.w700)),
      );
}

/// Group of rows in a white card with a small title.
class Group extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? trailing;
  const Group(this.title, this.children, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(children: [
              Expanded(child: Text(title, style: h(16))),
              if (trailing != null) trailing!,
            ]),
          ),
          Container(
            decoration: box(),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ]),
      );
}

/// Monthly / Weekly / Today switch like the reference design.
class PeriodSwitch extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final List<(String, String)> options;
  const PeriodSwitch({super.key, required this.value, required this.onChanged,
      this.options = const [('month', 'Monthly'), ('week', 'Weekly'), ('today', 'Today')]});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: C.soft, borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final o in options)
            GestureDetector(
              onTap: () => onChanged(o.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(color: value == o.$1 ? C.ink : Colors.transparent, borderRadius: BorderRadius.circular(8)),
                child: Text(o.$2, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: value == o.$1 ? Colors.white : C.muted)),
              ),
            ),
        ]),
      );
}

/// Dashboard tile: big number, label, progress bar (first tile dark like the design).
class StatTile extends StatelessWidget {
  final String value;
  final String label;
  final double progress; // 0..1
  final String note;
  final bool dark;
  final Color bar;
  final VoidCallback? onTap;
  const StatTile({super.key, required this.value, required this.label, this.progress = 0, this.note = '',
      this.dark = false, this.bar = C.lilac, this.onTap});
  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.white : C.text;
    final sub = dark ? const Color(0xFFCBD5E1) : C.muted;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: box(color: dark ? C.ink : C.card, border: !dark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: h(24, color: fg))),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: sub, fontSize: 13.5, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: Text(note, style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
            Text('${(progress.clamp(0, 1) * 100).round()}%', style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress.clamp(0, 1).toDouble(),
              minHeight: 7,
              color: dark ? Colors.white : bar,
              backgroundColor: dark ? const Color(0xFF33476B) : C.soft,
            ),
          ),
        ]),
      ),
    );
  }
}

/// Bar chart (two series side by side: e.g. this period vs the previous).
class BarChart extends StatelessWidget {
  final List<String> labels;
  final List<double> a;
  final List<double>? b;
  final double height;
  const BarChart({super.key, required this.labels, required this.a, this.b, this.height = 190});
  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: CustomPaint(painter: _BarPainter(labels, a, b), size: Size.infinite),
      );
}

class _BarPainter extends CustomPainter {
  final List<String> labels;
  final List<double> a;
  final List<double>? b;
  _BarPainter(this.labels, this.a, this.b);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 38.0, bottom = 22.0;
    final w = size.width - left, hgt = size.height - bottom;
    var maxV = a.fold<double>(0, (x, y) => math.max(x, y));
    if (b != null) maxV = math.max(maxV, b!.fold<double>(0, (x, y) => math.max(x, y)));
    final top = _niceMax(maxV);
    final grid = Paint()
      ..color = C.line
      ..strokeWidth = 1;
    for (var k = 0; k <= 4; k++) {
      final y = hgt - hgt * k / 4;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), grid);
      _text(canvas, short(top * k / 4), Offset(0, y - 7), 10, C.muted);
    }
    if (a.isEmpty) return;
    final slot = w / a.length;
    final pair = b != null;
    final bw = math.min(pair ? slot * 0.32 : slot * 0.55, 26.0);
    for (var i = 0; i < a.length; i++) {
      final cx = left + slot * i + slot / 2;
      if (pair) {
        _bar(canvas, cx - bw * 0.55, bw, hgt, a[i] / top * hgt, C.ink);
        _bar(canvas, cx + bw * 0.55, bw, hgt, b![i] / top * hgt, C.lilac);
      } else {
        _bar(canvas, cx, bw, hgt, a[i] / top * hgt, i == a.length - 1 ? C.ink : C.lilac);
      }
      final step = (a.length / 8).ceil();
      if (i % step == 0 || i == a.length - 1) {
        _text(canvas, labels[i], Offset(cx - 14, hgt + 6), 10, C.muted, width: 28, center: true);
      }
    }
  }

  void _bar(Canvas c, double cx, double bw, double base, double hh, Color color) {
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(cx - bw / 2, base - hh, bw, hh), const Radius.circular(5));
    c.drawRRect(r, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) => true;
}

/// Line chart with a soft fill (revenue over time).
class LineChart extends StatelessWidget {
  final List<String> labels;
  final List<double> a;
  final List<double>? b;
  final double height;
  const LineChart({super.key, required this.labels, required this.a, this.b, this.height = 190});
  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: CustomPaint(painter: _LinePainter(labels, a, b), size: Size.infinite),
      );
}

class _LinePainter extends CustomPainter {
  final List<String> labels;
  final List<double> a;
  final List<double>? b;
  _LinePainter(this.labels, this.a, this.b);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 38.0, bottom = 22.0;
    final w = size.width - left - 8, hgt = size.height - bottom;
    var maxV = a.fold<double>(0, (x, y) => math.max(x, y));
    if (b != null) maxV = math.max(maxV, b!.fold<double>(0, (x, y) => math.max(x, y)));
    final top = _niceMax(maxV);
    final grid = Paint()
      ..color = C.line
      ..strokeWidth = 1;
    for (var k = 0; k <= 4; k++) {
      final y = hgt - hgt * k / 4;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), grid);
      _text(canvas, short(top * k / 4), Offset(0, y - 7), 10, C.muted);
    }
    if (a.length < 2) return;
    Offset pt(List<double> v, int i) => Offset(left + w * i / (v.length - 1), hgt - v[i] / top * hgt);
    void series(List<double> v, Color line, Color fill) {
      final path = Path()..moveTo(pt(v, 0).dx, pt(v, 0).dy);
      for (var i = 1; i < v.length; i++) {
        path.lineTo(pt(v, i).dx, pt(v, i).dy);
      }
      final area = Path.from(path)
        ..lineTo(pt(v, v.length - 1).dx, hgt)
        ..lineTo(pt(v, 0).dx, hgt)
        ..close();
      canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [fill, fill.withValues(alpha: 0)])
                .createShader(Rect.fromLTWH(0, 0, size.width, hgt)));
      canvas.drawPath(
          path,
          Paint()
            ..color = line
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.4
            ..strokeJoin = StrokeJoin.round);
    }

    if (b != null && b!.length == a.length) series(b!, C.pink, C.pink.withValues(alpha: 0.25));
    series(a, C.ink, C.ink.withValues(alpha: 0.18));
    final last = pt(a, a.length - 1);
    canvas.drawCircle(last, 7, Paint()..color = Colors.white);
    canvas.drawCircle(
        last,
        7,
        Paint()
          ..color = C.ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
    final step = (a.length / 7).ceil();
    for (var i = 0; i < a.length; i++) {
      if (i % step == 0 || i == a.length - 1) {
        _text(canvas, labels[i], Offset(pt(a, i).dx - 14, hgt + 6), 10, C.muted, width: 28, center: true);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => true;
}

double _niceMax(double v) {
  if (v <= 0) return 100;
  final mag = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
  for (final m in [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]) {
    if (m * mag >= v) return m * mag;
  }
  return 10 * mag;
}

void _text(Canvas c, String t, Offset at, double size, Color color, {double width = 40, bool center = false}) {
  final tp = TextPainter(
    text: TextSpan(text: t, style: TextStyle(fontSize: size, color: color)),
    textAlign: center ? TextAlign.center : TextAlign.left,
    textDirection: TextDirection.ltr,
  )..layout(minWidth: center ? width : 0, maxWidth: width + 20);
  tp.paint(c, at);
}

/// Round avatar with initials.
class Avatar extends StatelessWidget {
  final String name;
  final double size;
  final Color bg;
  final Color fg;
  const Avatar(this.name, {super.key, this.size = 44, this.bg = C.soft, this.fg = C.ink});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Text(initials(name), style: h(size * 0.34, color: fg)),
      );
}

/// Choose one item from a list (bottom sheet with search).
Future<Map<String, Object?>?> pickFrom(BuildContext context, String title, List<Map<String, Object?>> items,
    {String Function(Map<String, Object?>)? label, String Function(Map<String, Object?>)? sub}) {
  String lab(Map<String, Object?> m) => label != null ? label(m) : s(m['name']);
  return showModalBottomSheet<Map<String, Object?>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: C.bg,
    builder: (ctx) {
      var q = '';
      return StatefulBuilder(builder: (ctx, set) {
        final shown = items.where((m) => q.isEmpty || lab(m).toLowerCase().contains(q.toLowerCase())).toList();
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.8,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(children: [Expanded(child: Text(title, style: h(18))), IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close))]),
              ),
              if (items.length > 8)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    decoration: const InputDecoration(hintText: 'Search', prefixIcon: Icon(Icons.search)),
                    onChanged: (v) => set(() => q = v),
                  ),
                ),
              Expanded(
                child: shown.isEmpty
                    ? const Empty(Icons.search_off, 'Nothing found.')
                    : ListView.separated(
                        itemCount: shown.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (_, k) => ListTile(
                          title: Text(lab(shown[k]), style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: sub == null ? null : Text(sub(shown[k])),
                          onTap: () => Navigator.pop(ctx, shown[k]),
                        ),
                      ),
              ),
            ]),
          ),
        );
      });
    },
  );
}

/// Section label used on long forms.
class Label extends StatelessWidget {
  final String text;
  const Label(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 16, 2, 8),
        child: Text(text, style: h(14.5, color: C.muted)),
      );
}

/// Row with a label and a value (statements, totals).
class KV extends StatelessWidget {
  final String k;
  final String v;
  final bool bold;
  final Color? color;
  const KV(this.k, this.v, {super.key, this.bold = false, this.color});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(children: [
          Expanded(child: Text(k, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w500, fontSize: 14.5))),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, fontSize: 14.5, color: color ?? C.text)),
        ]),
      );
}
