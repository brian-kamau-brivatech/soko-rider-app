import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class C {
  static const navy = Color(0xFF12304A);
  static const green = Color(0xFF0F766E); // teal: Utange
  static const greenDark = Color(0xFF115E59);
  static const greenLight = Color(0xFFDDF3F0);
  static const gold = Color(0xFFC8962E);
  static const bg = Color(0xFFF4F5F7);
  static const ink = Color(0xFF111827);
  static const muted = Color(0xFF4B5563);
  static const line = Color(0xFFE5E7EB);
  static const amber = Color(0xFFB45309);
  static const amberLight = Color(0xFFFEF3C7);
  static const red = Color(0xFFB91C1C);
  static const redLight = Color(0xFFFDECEC);
  static const blue = Color(0xFF1D4ED8);
  static const blueLight = Color(0xFFDBEAFE);
}

TextStyle h(double size, {FontWeight w = FontWeight.w800, Color color = C.ink}) =>
    GoogleFonts.plusJakartaSans(fontSize: size, fontWeight: w, color: color);

String ksh(double v) {
  final neg = v < 0;
  final s = v.abs().round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return '${neg ? '-' : ''}KSh $s';
}

String qty(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);
String signed(double q) => q > 0 ? '+${qty(q)}' : qty(q);

BoxDecoration card([double r = 18]) =>
    BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(r), border: Border.all(color: C.line));

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
        padding: const EdgeInsets.symmetric(vertical: 50, horizontal: 20),
        child: Column(children: [
          Icon(icon, size: 44, color: C.muted),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: C.muted, fontSize: 14.5)),
        ]),
      );
}

/// Loading / error / content in one place.
class Loader extends StatelessWidget {
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final Widget Function() child;
  const Loader({super.key, required this.loading, required this.error, required this.onRetry, required this.child});
  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return ListView(children: [
        EmptyNote(Icons.wifi_off_rounded, error!),
        Center(child: TextButton(onPressed: onRetry, child: const Text('Try again'))),
      ]);
    }
    if (loading) return const Center(child: CircularProgressIndicator(color: C.green));
    return child();
  }
}

class Pill extends StatelessWidget {
  final String text;
  final Color fg;
  final Color bg;
  const Pill(this.text, {super.key, this.fg = C.greenDark, this.bg = C.greenLight});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: h(11.5, color: fg)),
      );
}

/// Colours for a requisition state.
(Color, Color) reqColors(String state) => switch (state) {
      'submitted' => (C.amber, C.amberLight),
      'approved' => (C.blue, C.blueLight),
      'done' => (C.greenDark, C.greenLight),
      'rejected' => (C.red, C.redLight),
      _ => (C.muted, C.bg),
    };

AppBar bar(String title, {List<Widget>? actions}) => AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      title: Text(title, style: h(18)),
      actions: actions,
    );

Widget primaryButton(String label, VoidCallback? onPressed, {IconData? icon, Color color = C.green, bool busy = false}) =>
    SizedBox(
      height: 56,
      child: ElevatedButton.icon(
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : Icon(icon ?? Icons.check_rounded),
        label: Text(label, style: h(16.5, color: Colors.white)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: C.line,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
