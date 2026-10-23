import 'package:flutter/material.dart';

class C {
  // BRV Integrated Systems: navy and gold
  static const brand = Color(0xFF0A2348);
  static const brand2 = Color(0xFF1B3F73);
  static const brandLight = Color(0xFFE7ECF4);
  static const gold = Color(0xFFC38B2C);
  static const goldDark = Color(0xFF9E6E1C);
  static const goldLight = Color(0xFFF8EEDB);
  static const green = Color(0xFF0E8A55);
  static const greenLight = Color(0xFFE3F5EC);
  static const bg = Color(0xFFF4F6FA);
  static const ink = Color(0xFF111827);
  static const muted = Color(0xFF5B6576);
  static const line = Color(0xFFE2E7EE);
  static const amber = Color(0xFFA95C00);
  static const amberLight = Color(0xFFFFF3DF);
  static const red = Color(0xFFB4232A);
  static const redLight = Color(0xFFFDECEC);
}

TextStyle h(double size, {FontWeight w = FontWeight.w800, Color color = C.ink}) =>
    TextStyle(fontSize: size, fontWeight: w, color: color, letterSpacing: -0.2);

String money(double v, {bool symbol = true}) {
  final neg = v < 0;
  final s = v.abs().toStringAsFixed(2);
  final parts = s.split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return '${neg ? '-' : ''}${symbol ? 'KSh ' : ''}$whole.${parts[1]}';
}

String qtyText(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

BoxDecoration card([double r = 16]) => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(r),
      border: Border.all(color: C.line),
    );

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
}

class EmptyNote extends StatelessWidget {
  final IconData icon;
  final String text;
  const EmptyNote(this.icon, this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
        child: Column(children: [
          Icon(icon, size: 44, color: C.muted),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: C.muted, fontSize: 15)),
        ]),
      );
}

class Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? trailing;
  const Section(this.title, this.children, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(children: [
              Expanded(child: Text(title.toUpperCase(), style: h(12, color: C.muted).copyWith(letterSpacing: 0.8))),
              if (trailing != null) trailing!,
            ]),
          ),
          Container(
            decoration: card(),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ]),
      );
}

/// Small coloured label.
class Pill extends StatelessWidget {
  final String text;
  final Color fg;
  final Color bg;
  const Pill(this.text, {super.key, this.fg = C.muted, this.bg = C.bg});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: h(11.5, color: fg, w: FontWeight.w700)),
      );
}

InputDecoration field(String label, {String? hint, String? help, Widget? prefix}) => InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: help,
      helperMaxLines: 3,
      prefixIcon: prefix,
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.line)),
    );
