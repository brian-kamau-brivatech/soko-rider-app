import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'auth.dart';
import 'orders.dart';
import 'shell.dart';
import 'track.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final cat = store.catalog;
          if (cat == null && store.catalogError != null) {
            return ErrorRetry(store.catalogError!, () => store.loadCatalog(force: true));
          }
          return RefreshIndicator(
            color: C.green,
            onRefresh: () => store.loadCatalog(force: true),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
              children: [
                Row(children: [
                  Image.asset('assets/logo.png', height: 42),
                  const Spacer(),
                  SquareButton(
                    icon: store.signedIn ? Icons.person_rounded : Icons.person_outline_rounded,
                    tooltip: store.signedIn ? 'My account' : 'Sign in',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
                  ),
                  const SizedBox(width: 10),
                  SquareButton(
                    icon: Icons.shopping_cart_outlined,
                    tooltip: 'Cart',
                    badge: store.cartCount,
                    onTap: () => currentTab.value = 2,
                  ),
                ]),
                const SizedBox(height: 14),
                InkWell(
                  onTap: () => openShop(),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    height: 50,
                    padding: const EdgeInsets.only(left: 14, right: 6),
                    decoration: cardBox(14),
                    child: Row(children: [
                      const Icon(Icons.search_rounded, color: C.muted),
                      const SizedBox(width: 10),
                      const Expanded(child: Text('Search products…', style: TextStyle(color: C.muted, fontSize: 15))),
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(color: C.ink, borderRadius: BorderRadius.circular(11)),
                        child: const Icon(Icons.search_rounded, color: Colors.white, size: 20),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 14),
                const _ActiveOrderBanner(),
                _Hero(banner: cat?.banner ?? ''),
                const SizedBox(height: 14),
                const _Features(),
                const SizedBox(height: 8),
                if (cat == null)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator(color: C.green)),
                  )
                else ...[
                  if (cat.categories.isNotEmpty) ...[
                    SectionTitle('Shop by category', action: 'View All', onAction: () => openShop()),
                    SizedBox(
                      height: 104,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: cat.categories.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (_, i) => _CategoryTile(cat.categories[i]),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  SectionTitle('Deal of the Day', action: 'View All', onAction: () => openShop()),
                  SizedBox(
                    height: 250,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: cat.products.length > 10 ? 10 : cat.products.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 12),
                      itemBuilder: (_, i) => ProductCard(cat.products[i], width: 156),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  final String banner;
  const _Hero({required this.banner});
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 170,
        child: Stack(fit: StackFit.expand, children: [
          Container(color: C.greenDark),
          if (banner.isNotEmpty) NetImage(banner, fit: BoxFit.cover),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xF21C3E2C), Color(0xBF1C3E2C), Color(0x001C3E2C)], stops: [0, .5, .9]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('FRESHNESS YOU CAN TRUST',
                  style: TextStyle(color: Color(0xFFBFE3A6), fontSize: 10.5, letterSpacing: 2)),
              const SizedBox(height: 6),
              SizedBox(
                width: 200,
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: 'Fresh Groceries, ', style: head(21, color: Colors.white)),
                  TextSpan(text: 'Better Living', style: head(21, color: const Color(0xFF9BD46E))),
                ])),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () => openShop(),
                iconAlignment: IconAlignment.end,
                icon: const Icon(Icons.arrow_forward_rounded, size: 17),
                label: Text('SHOP NOW', style: head(12.5, w: FontWeight.w600, color: C.green)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: C.green,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Features extends StatelessWidget {
  const _Features();
  @override
  Widget build(BuildContext context) {
    Widget f(IconData i, String t, String s) => Expanded(
          child: Row(children: [
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(color: C.greenLight, shape: BoxShape.circle),
              child: Icon(i, size: 16, color: C.green),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: head(11.5, w: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(s, style: const TextStyle(fontSize: 11.5, color: C.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ]),
        );
    return Row(children: [
      f(Icons.eco_outlined, 'Farm Fresh', 'Quality produce'),
      f(Icons.local_shipping_outlined, 'Fast Delivery', 'To your door'),
      f(Icons.lock_outline_rounded, 'Secure Pay', 'M-Pesa'),
    ]);
  }
}

class _CategoryTile extends StatelessWidget {
  final Category c;
  const _CategoryTile(this.c);
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => openShop(c.id),
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 78,
          child: Column(children: [
            Container(
              width: 74,
              height: 74,
              clipBehavior: Clip.antiAlias,
              decoration: cardBox(16),
              child: NetImage(c.image, fit: BoxFit.cover),
            ),
            const SizedBox(height: 6),
            Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          ]),
        ),
      );
}

/// Shows the latest unfinished order at the top of Home.
class _ActiveOrderBanner extends StatefulWidget {
  const _ActiveOrderBanner();
  @override
  State<_ActiveOrderBanner> createState() => _ActiveOrderBannerState();
}

class _ActiveOrderBannerState extends State<_ActiveOrderBanner> {
  ShopOrder? _order;

  @override
  void initState() {
    super.initState();
    _load();
    ordersVersion.addListener(_load);
  }

  @override
  void dispose() {
    ordersVersion.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (!AppStore.instance.signedIn) {
      if (mounted) setState(() => _order = null);
      return;
    }
    try {
      final list = await ShopApi.orders(const [], session: AppStore.instance.session);
      final active = list.where((o) => !o.delivered && !o.cancelled && (o.paid || o.step > 0)).toList();
      if (mounted) setState(() => _order = active.isEmpty ? null : active.first);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    if (o == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TrackScreen(order: o))),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: C.accent, width: 1.5),
          ),
          child: Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(color: C.green, shape: BoxShape.circle),
              child: const Icon(Icons.delivery_dining_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(o.statusLabel, style: head(14.5, w: FontWeight.w600)),
                Text('${o.name} · tap to track', style: const TextStyle(fontSize: 13, color: C.muted)),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: C.muted),
          ]),
        ),
      ),
    );
  }
}
