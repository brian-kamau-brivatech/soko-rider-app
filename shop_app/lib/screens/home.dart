import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'order_detail.dart';
import 'shell.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _needsAction = true;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Store.i,
      builder: (context, _) {
        final s = Store.i;
        final b = s.board;
        final c = b?.counts ?? const {};
        final open = (b?.orders ?? const <ShopOrder>[]).where((o) => !o.isDone).toList();
        final list = _needsAction ? open.where((o) => o.needsAction).toList() : open;
        return Column(children: [
          // Navy header like the design.
          Container(
            width: double.infinity,
            color: C.navy,
            padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 14, 20, 18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Soko Shop', style: h(22, color: Colors.white)),
                    Text('${s.shopName} · Shop staff', style: const TextStyle(color: Color(0xFFC9D3E0), fontSize: 13)),
                  ]),
                ),
                _ReceivingPill(error: s.error),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                _Stat('New · needs action', c['new'] ?? 0, C.green, onTap: () => tab.value = 1),
                const SizedBox(width: 8),
                _Stat('Preparing', c['preparing'] ?? 0, const Color(0xFFF59E0B), onTap: () => tab.value = 1),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                _Stat('Out for delivery', c['out'] ?? 0, const Color(0xFF60A5FA), onTap: () => tab.value = 1),
                const SizedBox(width: 8),
                _Stat('Delivered today', c['delivered'] ?? 0, const Color(0xFF9CA3AF), onTap: () => tab.value = 1),
              ]),
            ]),
          ),
          Expanded(
            child: RefreshIndicator(
              color: C.green,
              onRefresh: s.refresh,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 20), children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
                  child: Row(children: [
                    _seg('Needs action', _needsAction, () => setState(() => _needsAction = true)),
                    _seg('All orders', !_needsAction, () => setState(() => _needsAction = false)),
                  ]),
                ),
                const SizedBox(height: 12),
                if (b == null && s.error == null)
                  const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: C.green)))
                else if (b == null)
                  EmptyNote(Icons.wifi_off_rounded, s.error!)
                else if (list.isEmpty)
                  EmptyNote(Icons.check_circle_outline_rounded, _needsAction ? 'Nothing needs action right now.' : 'No open orders.')
                else
                  for (final o in list)
                    OrderCard(o,
                        onTap: () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => OrderDetailScreen(orderId: o.id, preview: o)))),
              ]),
            ),
          ),
        ]);
      },
    );
  }

  Widget _seg(String label, bool on, VoidCallback tap) => Expanded(
        child: InkWell(
          onTap: tap,
          borderRadius: BorderRadius.circular(11),
          child: Container(
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: on ? C.navy : Colors.transparent, borderRadius: BorderRadius.circular(11)),
            child: Text(label, style: h(13.5, w: FontWeight.w700, color: on ? Colors.white : C.muted)),
          ),
        ),
      );
}

class _Stat extends StatelessWidget {
  final String label;
  final int value;
  final Color dot;
  final VoidCallback onTap;
  const _Stat(this.label, this.value, this.dot, {required this.onTap});
  @override
  Widget build(BuildContext context) => Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFF16345A), borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$value', style: h(24, color: Colors.white)),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFC9D3E0), fontSize: 12)),
                ]),
              ),
              Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            ]),
          ),
        ),
      );
}

class _ReceivingPill extends StatelessWidget {
  final String? error;
  const _ReceivingPill({this.error});
  @override
  Widget build(BuildContext context) {
    final ok = error == null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: ok ? const Color(0x332E8B1E) : const Color(0x33B91C1C),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: ok ? const Color(0xFF7BD66A) : const Color(0xFFF87171), shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(ok ? 'Receiving' : 'Offline', style: h(12.5, color: Colors.white)),
      ]),
    );
  }
}
