import 'package:flutter/material.dart';
import '../store.dart';
import '../ui.dart';
import 'order_detail.dart';

/// Full-screen ringing alert (new paid order / no rider found).
class AlertScreen extends StatelessWidget {
  final ShopAlert alert;
  const AlertScreen({super.key, required this.alert});

  @override
  Widget build(BuildContext context) {
    final o = alert.order;
    final isNew = alert.kind == 'new';
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) Store.i.silence();
      },
      child: Scaffold(
      backgroundColor: isNew ? C.navy : const Color(0xFF7F1D1D),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Text('SOKO SHOP', style: h(13, color: const Color(0xFFC9D3E0)).copyWith(letterSpacing: 1.5)),
              const Spacer(),
              const Icon(Icons.notifications_active_rounded, color: Colors.white),
              const SizedBox(width: 6),
              Text('Ringing', style: h(13, color: Colors.white)),
            ]),
            const SizedBox(height: 26),
            Text(isNew ? 'New order' : 'No rider found', style: h(34, color: Colors.white)),
            const SizedBox(height: 4),
            Text('${o.trackingNo}${o.soName.isEmpty ? '' : ' · ${o.soName}'} · ${o.ago}',
                style: const TextStyle(color: Color(0xFFC9D3E0), fontSize: 15)),
            const SizedBox(height: 22),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(ksh(o.amount), style: h(30))),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: o.paid ? C.greenLight : C.redLight, borderRadius: BorderRadius.circular(999)),
                    child: Text(o.paid ? 'PAID · M-PESA' : 'NOT PAID', style: h(12, color: o.paid ? C.greenDark : C.red)),
                  ),
                ]),
                if (o.customer.isNotEmpty || o.customerPhone.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text([if (o.customer.isNotEmpty) o.customer, if (o.customerPhone.isNotEmpty) o.customerPhone].join(' · '),
                      style: h(16, w: FontWeight.w700)),
                ],
                const SizedBox(height: 10),
                Text(o.items.isEmpty ? '${o.count} items' : o.items, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text([if (o.address.isNotEmpty) o.address, if (o.km > 0) '${o.km.toStringAsFixed(1)} km', 'delivery ${ksh(o.fee)}'].join(' · '),
                    style: const TextStyle(color: C.muted)),
                const Divider(height: 24, color: C.line),
                Row(children: [
                  Icon(Icons.two_wheeler_rounded, color: isNew ? C.green : C.red),
                  const SizedBox(width: 8),
                  Expanded(child: Text(o.riderLine, style: h(14.5, w: FontWeight.w700, color: isNew ? C.ink : C.red))),
                ]),
              ]),
            ),
            const Spacer(),
            SizedBox(
              height: 58,
              child: ElevatedButton(
                onPressed: () async {
                  await Store.i.silence();
                  if (!context.mounted) return;
                  Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => OrderDetailScreen(orderId: o.id, preview: o)));
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: C.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: Text(isNew ? 'Open order' : 'Assign a rider', style: h(17, color: Colors.white)),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 52,
              child: OutlinedButton(
                onPressed: () async {
                  await Store.i.silence();
                  if (context.mounted) Navigator.of(context).pop();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white54),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: Text('Silence for now', style: h(15.5, color: Colors.white)),
              ),
            ),
          ]),
        ),
      ),
    ),
    );
  }
}
