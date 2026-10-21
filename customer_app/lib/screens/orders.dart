import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'shell.dart';
import 'track.dart';

/// Bumped whenever orders may have changed, so lists reload.
final ValueNotifier<int> ordersVersion = ValueNotifier<int>(0);

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<ShopOrder>? _orders;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    currentTab.addListener(_onTab);
    AppStore.instance.addListener(_onStore);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  int _known = -1;
  void _onStore() {
    if (AppStore.instance.orderRefs.length != _known) _load();
  }

  void _onTab() {
    if (currentTab.value == 3) _load();
  }

  @override
  void dispose() {
    currentTab.removeListener(_onTab);
    AppStore.instance.removeListener(_onStore);
    super.dispose();
  }

  Future<void> _load() async {
    final refs = AppStore.instance.orderRefs;
    _known = refs.length;
    if (!mounted) return;
    if (refs.isEmpty) {
      setState(() => _orders = []);
      return;
    }
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ShopApi.orders(refs);
      if (mounted) setState(() => _orders = list);
      ordersVersion.value++;
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final orders = _orders;
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: C.green,
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          children: [
            Text('My Orders', style: head(20)),
            const SizedBox(height: 14),
            if (orders == null && _error == null)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: C.green)))
            else if (orders == null)
              ErrorRetry(_error!, _load)
            else if (orders.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 80),
                child: Column(children: [
                  const Icon(Icons.receipt_long_outlined, size: 48, color: C.muted),
                  const SizedBox(height: 12),
                  const Text('No orders yet.', style: TextStyle(color: C.muted, fontSize: 15)),
                  const SizedBox(height: 18),
                  SizedBox(width: 200, child: PrimaryButton('Start shopping', onTap: () => openShop())),
                ]),
              )
            else
              for (final o in orders) _OrderCard(o, onBack: _load),
          ],
        ),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final ShopOrder o;
  final VoidCallback onBack;
  const _OrderCard(this.o, {required this.onBack});

  @override
  Widget build(BuildContext context) {
    final color = o.cancelled
        ? const Color(0xFFB91C1C)
        : o.delivered
            ? C.green
            : o.step == 0
                ? const Color(0xFFB45309)
                : C.accent;
    final date = o.date.length >= 10 ? o.date.substring(0, 10) : o.date;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TrackScreen(order: o)));
          onBack();
        },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: cardBox(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(o.name, style: head(15.5, w: FontWeight.w600))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
                child: Text(o.statusLabel, style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              height: 44,
              child: Row(children: [
                for (final l in o.lines.take(5))
                  Container(
                    width: 44,
                    height: 44,
                    margin: const EdgeInsets.only(right: 6),
                    clipBehavior: Clip.antiAlias,
                    decoration: cardBox(10),
                    child: NetImage(l.thumb),
                  ),
                if (o.lines.length > 5) Text('+${o.lines.length - 5}', style: const TextStyle(color: C.muted)),
              ]),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Text('$date · ${o.itemCount} items', style: const TextStyle(color: C.muted, fontSize: 13.5))),
              Text(money(o.amountTotal), style: head(15, w: FontWeight.w600)),
            ]),
          ]),
        ),
      ),
    );
  }
}
