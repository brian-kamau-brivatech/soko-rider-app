import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';

class RidersScreen extends StatelessWidget {
  const RidersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: Store.i,
        builder: (context, _) {
          final riders = [...(Store.i.board?.riders ?? const <Rider>[])]
            ..sort((a, b) => _rank(a).compareTo(_rank(b)) != 0 ? _rank(a).compareTo(_rank(b)) : a.km.compareTo(b.km));
          final free = riders.where((r) => r.isFree).length;
          final busy = riders.where((r) => r.isBusy).length;
          final off = riders.where((r) => r.isOffline).length;
          return RefreshIndicator(
            color: C.green,
            onRefresh: Store.i.refresh,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 20), children: [
              Text('Riders', style: h(22)),
              const SizedBox(height: 12),
              Row(children: [
                _count('Free', free, C.green),
                const SizedBox(width: 8),
                _count('On delivery', busy, const Color(0xFFF59E0B)),
                const SizedBox(width: 8),
                _count('Offline', off, const Color(0xFF9CA3AF)),
              ]),
              const SizedBox(height: 14),
              if (riders.isEmpty)
                const EmptyNote(Icons.two_wheeler_outlined, 'No approved riders yet.')
              else
                for (final r in riders) _RiderTile(r),
            ]),
          );
        },
      ),
    );
  }

  static int _rank(Rider r) => r.atShop ? 0 : r.isFree ? 1 : r.isBusy ? 2 : 3;

  Widget _count(String label, int n, Color c) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: card(14),
          child: Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5, color: C.muted))),
            Text('$n', style: h(18)),
          ]),
        ),
      );
}

class _RiderTile extends StatelessWidget {
  final Rider r;
  const _RiderTile(this.r);
  @override
  Widget build(BuildContext context) {
    late String chip, line;
    late Color color;
    if (r.atShop) {
      chip = 'AT SHOP';
      color = C.blue;
      line = 'At the shop${r.order.isEmpty ? '' : ' · ${r.order}'}';
    } else if (r.isFree) {
      chip = 'FREE';
      color = C.green;
      line = 'Free · ${r.km.toStringAsFixed(1)} km from shop';
    } else if (r.isBusy) {
      chip = 'BUSY';
      color = C.amber;
      line = 'Delivering${r.order.isEmpty ? '' : ' ${r.order}'}';
    } else {
      chip = 'OFFLINE';
      color = C.muted;
      line = 'Offline${r.lastSeen.isEmpty ? '' : ' · last seen ${r.lastSeen}'}';
    }
    final initials = r.name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => w[0].toUpperCase()).join();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: card(),
      child: Row(children: [
        CircleAvatar(radius: 22, backgroundColor: r.isOffline ? C.line : C.navy, child: Text(initials, style: h(14, color: Colors.white))),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.name, style: h(15)),
            Text(line, style: const TextStyle(fontSize: 13, color: C.muted)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
          child: Text(chip, style: h(11, color: color)),
        ),
        if (r.phone.isNotEmpty && !r.isOffline)
          IconButton(
            tooltip: 'Call ${r.name}',
            onPressed: () => callNumber(context, r.phone),
            icon: const Icon(Icons.phone_rounded, color: C.green),
          ),
      ]),
    );
  }
}
