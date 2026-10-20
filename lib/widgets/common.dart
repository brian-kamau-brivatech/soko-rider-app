import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class SokoColors {
  static const Color navy = Color(0xFF0C2340);
  static const Color ink = Color(0xFF111827); // headings
  static const Color sheet = Color(0xFF1C1F24); // dark tracking sheet
  static const Color sheetLine = Color(0xFF2E333A);
  static const Color green = Color(0xFF3CA227);
  static const Color leaf = Color(0xFF7EBB55); // website theme colour
  static const Color greenLight = Color(0xFFEAF5E3);
  static const Color greenTint = Color(0xFFF3F8EC);
  static const Color slate = Color(0xFF6B7280);
  static const Color line = Color(0xFFE5E7EB);
  static const Color red = Color(0xFFDC2626);
  static const Color redLight = Color(0xFFFEE2E2);
  static const Color background = Color(0xFFF4F5F7);
}

const sokoLogoUrl = 'https://sokoexpressmtaani.co.ke/theme_soko/static/src/img/logo.png';

/// "KSh 1,250.00" or "—" when the server did not send a value.
String formatKsh(double? v, {bool decimals = false}) {
  if (v == null) return '—';
  final fixed = v.toStringAsFixed(decimals ? 2 : 0);
  final parts = fixed.split('.');
  final whole = parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0 && whole[i - 1] != '-') buf.write(',');
    buf.write(whole[i]);
  }
  return 'KSh $buf${parts.length > 1 ? '.${parts[1]}' : ''}';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "20 Oct 12:45"
String formatDateTime(DateTime d) =>
    '${d.day} ${_months[d.month - 1]} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// "20 Oct 2026"
String formatDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// Emoji for an order based on what was bought (purely decorative).
String orderEmoji(String items) {
  final s = items.toLowerCase();
  const map = {
    'milk': '🥛', 'egg': '🥚', 'potato': '🥔', 'onion': '🧅', 'tomato': '🍅',
    'orange': '🍊', 'banana': '🍌', 'apple': '🍎', 'cabbage': '🥬', 'kale': '🥬',
    'sukuma': '🥬', 'spinach': '🥬', 'vegetable': '🥬', 'carrot': '🥕', 'fruit': '🍉',
    'meat': '🥩', 'chicken': '🍗', 'bread': '🍞', 'flour': '🌾', 'rice': '🍚',
  };
  for (final e in map.entries) {
    if (s.contains(e.key)) return e.value;
  }
  return '📦';
}

/// Opens Google Maps (or any maps app) with driving directions to the point.
Future<void> openNavigation(BuildContext context, double lat, double lng) async {
  final google = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving');
  final geo = Uri.parse('geo:$lat,$lng?q=$lat,$lng');
  try {
    if (await launchUrl(google, mode: LaunchMode.externalApplication)) return;
  } catch (_) {}
  try {
    if (await launchUrl(geo, mode: LaunchMode.externalApplication)) return;
  } catch (_) {}
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No maps app found on this phone.')));
  }
}

Future<void> callPhone(BuildContext context, String phone) async {
  final uri = Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'\s+'), ''));
  try {
    if (await launchUrl(uri)) return;
  } catch (_) {}
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open dialer for $phone')));
  }
}

Future<void> smsPhone(BuildContext context, String phone, {String body = ''}) async {
  final uri = Uri(
    scheme: 'sms',
    path: phone.replaceAll(RegExp(r'\s+'), ''),
    queryParameters: body.isEmpty ? null : {'body': body},
  );
  try {
    if (await launchUrl(uri)) return;
  } catch (_) {}
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open messages for $phone')));
  }
}

/// White rounded card used across the app.
class SokoCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final Color borderColor;
  final VoidCallback? onTap;
  const SokoCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color = Colors.white,
    this.borderColor = SokoColors.line,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: BorderSide(color: borderColor)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

/// Small rounded status label, e.g. "In Transit" / "Delivered".
class StatusPill extends StatelessWidget {
  final String text;
  final bool dark;
  const StatusPill(this.text, {super.key, this.dark = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: dark ? SokoColors.green.withOpacity(0.15) : SokoColors.greenLight,
        borderRadius: BorderRadius.circular(20),
        border: dark ? Border.all(color: SokoColors.green.withOpacity(0.6)) : null,
      ),
      child: Text(text,
          style: TextStyle(color: dark ? const Color(0xFF7BD66A) : SokoColors.green, fontWeight: FontWeight.w700, fontSize: 13)),
    );
  }
}

/// Placed → Picked up → In transit → Delivered, as dots joined by a line.
class ProgressSteps extends StatelessWidget {
  final int step; // 0..3
  final bool dark;
  final String? currentBadge;
  const ProgressSteps({super.key, required this.step, this.dark = false, this.currentBadge});

  @override
  Widget build(BuildContext context) {
    final idle = dark ? const Color(0xFF4B5563) : const Color(0xFFD1D5DB);
    Widget dot(int i) {
      final done = i < step;
      final current = i == step;
      return Container(
        width: current ? 26 : 22,
        height: current ? 26 : 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done ? SokoColors.green : (dark ? SokoColors.sheet : Colors.white),
          border: Border.all(color: done || current ? SokoColors.green : idle, width: current ? 4 : 2),
          boxShadow: current ? [BoxShadow(color: SokoColors.green.withOpacity(0.35), blurRadius: 8)] : null,
        ),
        child: done && !dark ? const Icon(Icons.check, size: 13, color: Colors.white) : null,
      );
    }

    final children = <Widget>[];
    for (var i = 0; i < 4; i++) {
      if (i > 0) {
        children.add(Expanded(child: Container(height: 3, color: i <= step ? SokoColors.green : idle)));
      }
      children.add(dot(i));
    }
    final row = Row(children: children);
    if (currentBadge == null || step >= 3) return row;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        row,
        Positioned.fill(
          top: -24,
          child: Align(
            alignment: Alignment(-1 + step * 2 / 3, -1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: SokoColors.ink, borderRadius: BorderRadius.circular(8)),
              child: Text(currentBadge!, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ],
    );
  }
}

/// Red box with a message and a retry button.
class ErrorPanel extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const ErrorPanel({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: SokoColors.redLight, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: SokoColors.red),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(color: SokoColors.red, fontSize: 13))),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
