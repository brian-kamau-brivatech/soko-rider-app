import 'package:flutter/material.dart';
import '../config.dart';
import '../models/delivery_order.dart';
import '../services/odoo_service.dart';
import '../services/presence_service.dart';
import '../services/push_service.dart';
import '../services/rider_data.dart';
import '../widgets/common.dart';
import 'active_delivery_screen.dart';
import 'dashboard_screen.dart';
import 'earnings_screen.dart';
import 'offer_screen.dart';
import 'orders_screen.dart';
import 'profile_screen.dart';

/// Home with the floating dark nav bar: Home · Orders · (refresh) · Track · Profile.
class HomeShell extends StatefulWidget {
  final OdooService odooService;
  const HomeShell({super.key, required this.odooService});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  late final RiderData _data = RiderData(widget.odooService);
  late final PresenceService _presence = PresenceService(widget.odooService);
  int _tab = 0; // 0 home, 1 orders, 2 profile, 3 earnings
  final _earningsTick = ValueNotifier<int>(0);
  bool _offerOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _data.refresh();
    _data.startAutoRefresh();
    _presence.onNewOffer = _showOffer;
    PushService.instance.onDispatchPush = _presence.checkOffers;
    _presence.restore();
    PushService.instance.registerWith(widget.odooService);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PushService.instance.onDispatchPush = null;
    _earningsTick.dispose();
    _presence.dispose();
    _data.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check orders, requests and GPS after the rider returns to the app.
    if (state == AppLifecycleState.resumed) {
      _data.refresh();
      _presence.checkOffers();
    }
  }

  Future<void> _showOffer(DispatchOffer offer) async {
    if (_offerOpen || !mounted) return;
    _offerOpen = true;
    final accepted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => OfferScreen(offer: offer, presence: _presence)),
    );
    _offerOpen = false;
    if (!mounted) return;
    await _data.refresh();
    if (!mounted) return;
    if (accepted == true) {
      _go(0);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Order ${offer.order.trackingNo} is yours. Head to the shop to pick it up.'),
        action: SnackBarAction(label: 'Navigate', onPressed: () => openNavigation(context, AppConfig.shopLatitude, AppConfig.shopLongitude)),
      ));
    }
    // Another request may be waiting.
    for (final o in _presence.offers) {
      if (o.id != offer.id && o.expiresAt.isAfter(DateTime.now())) {
        _showOffer(o);
        break;
      }
    }
  }

  void _go(int tab) {
    if (tab == 3) _earningsTick.value++;
    setState(() => _tab = tab);
    if (tab == 1) _data.markAllSeen();
  }

  Future<void> openTracking(DeliveryOrder order) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ActiveDeliveryScreen(order: order, odooService: widget.odooService)),
    );
    _data.refresh();
  }

  Future<void> _checkNew() async {
    final before = _data.activeOrders.map((o) => o.id).toSet();
    await _presence.checkOffers();
    await _data.refresh();
    if (!mounted) return;
    final msg = !(_data.active?.ok ?? false)
        ? (_data.active?.error ?? 'Could not reach Soko server.')
        : () {
            final added = _data.activeOrders.where((o) => !before.contains(o.id)).length;
            if (added > 0) return '$added new order(s) assigned to you.';
            return _data.activeOrders.isEmpty ? 'No orders assigned yet.' : 'No new orders.';
          }();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SokoColors.background,
      extendBody: true,
      body: IndexedStack(
        index: _tab,
        children: [
          DashboardScreen(data: _data, presence: _presence, onOpen: openTracking, onSeeOrders: () => _go(1)),
          OrdersScreen(data: _data, onOpen: openTracking),
          ProfileScreen(data: _data, presence: _presence),
          EarningsScreen(odooService: widget.odooService, refreshTick: _earningsTick),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          height: 72,
          decoration: BoxDecoration(
            color: SokoColors.ink,
            borderRadius: BorderRadius.circular(30),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 20, offset: const Offset(0, 8))],
          ),
          child: Row(
            children: [
              _NavItem(icon: Icons.home_outlined, active: Icons.home, label: 'Home', selected: _tab == 0, onTap: () => _go(0)),
              _NavItem(
                icon: Icons.inventory_2_outlined,
                active: Icons.inventory_2,
                label: 'Orders',
                selected: _tab == 1,
                onTap: () => _go(1),
                badge: AnimatedBuilder(
                  animation: _data,
                  builder: (_, __) => _data.newOrderCount > 0
                      ? Container(width: 8, height: 8, decoration: const BoxDecoration(color: SokoColors.red, shape: BoxShape.circle))
                      : const SizedBox.shrink(),
                ),
              ),
              Expanded(
                child: Center(
                  child: AnimatedBuilder(
                    animation: _data,
                    builder: (_, __) => GestureDetector(
                      onTap: _data.loading ? null : _checkNew,
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: SokoColors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: SokoColors.ink, width: 4),
                          boxShadow: [BoxShadow(color: SokoColors.green.withOpacity(0.5), blurRadius: 14)],
                        ),
                        child: _data.loading
                            ? const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                            : const Icon(Icons.sync, color: Colors.white, size: 28),
                      ),
                    ),
                  ),
                ),
              ),
              _NavItem(icon: Icons.account_balance_wallet_outlined, active: Icons.account_balance_wallet, label: 'Earnings', selected: _tab == 3, onTap: () => _go(3)),
              _NavItem(icon: Icons.person_outline, active: Icons.person, label: 'Profile', selected: _tab == 2, onTap: () => _go(2)),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData active;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? badge;
  const _NavItem({required this.icon, required this.active, required this.label, required this.selected, required this.onTap, this.badge});

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.white : Colors.white.withOpacity(0.6);
    return Expanded(
      child: InkResponse(
        onTap: onTap,
        radius: 36,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(clipBehavior: Clip.none, children: [
              Icon(selected ? active : icon, color: color, size: 26),
              if (badge != null) Positioned(right: -2, top: -2, child: badge!),
            ]),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: selected ? FontWeight.w800 : FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
