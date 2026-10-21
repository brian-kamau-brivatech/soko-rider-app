import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api.dart';

class C {
  static const navy = Color(0xFF0C2340);
  static const green = Color(0xFF2E8B1E);
  static const greenDark = Color(0xFF1F5A14);
  static const greenLight = Color(0xFFE3F2DD);
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
  final s = v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return 'KSh $s';
}

BoxDecoration card([double r = 18]) => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(r),
      border: Border.all(color: C.line),
    );

/// Coloured status chip (NEW, PREPARING, NOT PAID, OUT, DELIVERED).
class StatusChip extends StatelessWidget {
  final ShopOrder o;
  const StatusChip(this.o, {super.key});
  @override
  Widget build(BuildContext context) {
    late Color bg, fg;
    if (o.isDone) {
      bg = C.bg;
      fg = C.muted;
    } else if (o.isOut) {
      bg = C.blueLight;
      fg = C.blue;
    } else if (o.isPreparing) {
      bg = C.amberLight;
      fg = C.amber;
    } else if (!o.paid) {
      bg = C.redLight;
      fg = C.red;
    } else {
      bg = C.greenLight;
      fg = C.greenDark;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(o.statusLabel, style: h(11.5, color: fg).copyWith(letterSpacing: 0.4)),
    );
  }
}

/// One order in a list (Home and Orders tabs).
class OrderCard extends StatelessWidget {
  final ShopOrder o;
  final VoidCallback onTap;
  const OrderCard(this.o, {super.key, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final warn = o.noRider || (!o.paid && o.isNew);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: o.isNew && o.paid && o.rider.isEmpty ? C.green : C.line, width: o.isNew && o.paid && o.rider.isEmpty ? 1.6 : 1),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text('${o.trackingNo}${o.soName.isEmpty ? '' : ' · ${o.soName}'}',
                      style: h(15), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                StatusChip(o),
              ]),
              if (o.customer.isNotEmpty || o.customerPhone.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.person_rounded, size: 15, color: C.navy),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text([if (o.customer.isNotEmpty) o.customer, if (o.customerPhone.isNotEmpty) o.customerPhone].join(' · '),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: h(13.5, w: FontWeight.w700)),
                  ),
                ]),
              ],
              const SizedBox(height: 6),
              Text(o.items.isEmpty ? '${o.count} items' : o.items,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, color: C.muted)),
              const SizedBox(height: 4),
              Text([if (o.address.isNotEmpty) o.address, if (o.km > 0) '${o.km.toStringAsFixed(1)} km', o.ago].join(' · '),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: C.muted)),
              const SizedBox(height: 10),
              Row(children: [
                Icon(o.riderAtShop ? Icons.storefront_rounded : Icons.two_wheeler_rounded,
                    size: 18, color: warn ? C.red : C.green),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(o.riderLine,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: warn ? C.red : C.ink)),
                ),
                Text(ksh(o.amount), style: h(15)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

Future<void> callNumber(BuildContext context, String phone) async {
  if (phone.isEmpty) return;
  final ok = await launchUrl(Uri(scheme: 'tel', path: phone));
  if (!ok && context.mounted) toast(context, 'Could not open the phone app.');
}

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
        padding: const EdgeInsets.symmetric(vertical: 50),
        child: Column(children: [
          Icon(icon, size: 44, color: C.muted),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: C.muted, fontSize: 14.5)),
        ]),
      );
}
