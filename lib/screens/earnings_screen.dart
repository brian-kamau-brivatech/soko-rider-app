import 'package:flutter/material.dart';
import '../models/delivery_order.dart';
import '../services/odoo_service.dart';
import '../widgets/common.dart';

/// Total earnings, what Soko has paid and what is still owed, ride by ride.
class EarningsScreen extends StatefulWidget {
  final OdooService odooService;
  /// Bumped by the home shell to ask for a reload (e.g. tab opened).
  final ValueNotifier<int> refreshTick;
  const EarningsScreen({super.key, required this.odooService, required this.refreshTick});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

enum _Filter { all, unpaid, paid }

class _EarningsScreenState extends State<EarningsScreen> {
  EarningsResult? _data;
  bool _loading = false;
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    widget.refreshTick.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.refreshTick.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || !mounted) return;
    setState(() => _loading = true);
    final res = await widget.odooService.getEarnings();
    if (!mounted) return;
    setState(() {
      _data = res;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final rides = d?.rides ?? const <DeliveryOrder>[];
    final shown = rides.where((r) {
      switch (_filter) {
        case _Filter.all:
          return true;
        case _Filter.unpaid:
          return !r.isPaid;
        case _Filter.paid:
          return r.isPaid;
      }
    }).toList();
    final unpaidCount = rides.where((r) => !r.isPaid).length;

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: _load,
        color: SokoColors.green,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 120),
          children: [
            const Text('Earnings', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: SokoColors.ink)),
            const SizedBox(height: 16),
            if (d == null)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: SokoColors.green)))
            else if (d.error != null)
              ErrorPanel(message: d.error!, onRetry: _load)
            else ...[
              // Total
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: SokoColors.sheet, borderRadius: BorderRadius.circular(24)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TOTAL EARNED', style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
                    const SizedBox(height: 6),
                    Text(formatKsh(d.totalEarned, decimals: true),
                        style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800)),
                    Text('${rides.length} delivered ride${rides.length == 1 ? '' : 's'}',
                        style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _tile('Unpaid', formatKsh(d.totalUnpaid, decimals: true), SokoColors.red, const Color(0xFFFEF2F2), '$unpaidCount ride${unpaidCount == 1 ? '' : 's'}')),
                const SizedBox(width: 12),
                Expanded(child: _tile('Paid', formatKsh(d.totalPaid, decimals: true), SokoColors.green, SokoColors.greenTint, '${rides.length - unpaidCount} ride${rides.length - unpaidCount == 1 ? '' : 's'}')),
              ]),
              const SizedBox(height: 22),

              // Filter
              Row(children: [
                const Text('Rides', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: SokoColors.ink)),
                const Spacer(),
                SegmentedButton<_Filter>(
                  segments: const [
                    ButtonSegment(value: _Filter.all, label: Text('All')),
                    ButtonSegment(value: _Filter.unpaid, label: Text('Unpaid')),
                    ButtonSegment(value: _Filter.paid, label: Text('Paid')),
                  ],
                  selected: {_filter},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _filter = s.first),
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                ),
              ]),
              const SizedBox(height: 12),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 30),
                  child: Text(
                    rides.isEmpty ? 'No delivered rides yet.' : 'Nothing here.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: SokoColors.slate),
                  ),
                ),
              for (final r in shown) _rideRow(r),

              if (d.payouts.isNotEmpty) ...[
                const SizedBox(height: 22),
                const Text('Payments received', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: SokoColors.ink)),
                const SizedBox(height: 12),
                for (final p in d.payouts) _payoutRow(p),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _tile(String label, String value, Color fg, Color bg, String sub) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(color: fg, fontSize: 20, fontWeight: FontWeight.w800)),
          Text(sub, style: const TextStyle(color: SokoColors.slate, fontSize: 12)),
        ]),
      );

  Widget _rideRow(DeliveryOrder r) {
    final when = r.deliveredAt != null ? formatDateTime(r.deliveredAt!) : '';
    final sub = [
      if (when.isNotEmpty) when,
      if (r.distanceKm != null) '${r.distanceKm!.toStringAsFixed(1)} km',
      if (r.deliveryArea.isNotEmpty) r.deliveryArea,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SokoCard(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.trackingNo, style: const TextStyle(fontWeight: FontWeight.w800, color: SokoColors.ink, fontSize: 15)),
              if (sub.isNotEmpty)
                Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: SokoColors.slate, fontSize: 12)),
              if (r.isPaid && r.payoutRef.isNotEmpty)
                Text('Paid in ${r.payoutRef}${r.paidDate != null ? ' on ${formatDate(r.paidDate!)}' : ''}',
                    style: const TextStyle(color: SokoColors.green, fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(formatKsh(r.riderPayout ?? 0, decimals: true),
                style: const TextStyle(fontWeight: FontWeight.w800, color: SokoColors.ink, fontSize: 15)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: r.isPaid ? SokoColors.greenLight : const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(r.isPaid ? 'Paid' : 'Unpaid',
                  style: TextStyle(color: r.isPaid ? SokoColors.green : SokoColors.red, fontWeight: FontWeight.w800, fontSize: 12)),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _payoutRow(Map<String, dynamic> p) {
    final amount = p['amount'] is num ? (p['amount'] as num).toDouble() : 0.0;
    final date = p['paid_date'] is String ? DateTime.tryParse(p['paid_date'] as String) : null;
    final details = [
      if (date != null) formatDate(date),
      if ((p['method'] ?? '').toString().isNotEmpty) p['method'].toString(),
      if ((p['reference'] ?? '').toString().isNotEmpty) p['reference'].toString(),
      if (p['rides'] is int) '${p['rides']} rides',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SokoCard(
        padding: const EdgeInsets.all(14),
        color: SokoColors.greenTint,
        borderColor: SokoColors.leaf.withOpacity(0.35),
        child: Row(children: [
          const Icon(Icons.verified, color: SokoColors.green),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((p['ref'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w800, color: SokoColors.ink)),
              if (details.isNotEmpty) Text(details, style: const TextStyle(color: SokoColors.slate, fontSize: 12)),
            ]),
          ),
          Text(formatKsh(amount, decimals: true), style: const TextStyle(fontWeight: FontWeight.w800, color: SokoColors.green)),
        ]),
      ),
    );
  }
}
