import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../config.dart';
import '../models/delivery_order.dart';
import '../services/location_stream_service.dart';
import '../services/rider_data.dart';
import '../widgets/common.dart';
import '../widgets/order_card.dart';

/// Rider home ("Delivery Hub"). Every number on it comes from the Soko server.
class DashboardScreen extends StatefulWidget {
  final RiderData data;
  final Future<void> Function(DeliveryOrder) onOpen;
  final VoidCallback onSeeOrders;
  const DashboardScreen({super.key, required this.data, required this.onOpen, required this.onSeeOrders});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _fixGps() async {
    if (widget.data.gpsProblem == LiveStatus.gpsOff) {
      await Geolocator.openLocationSettings();
    } else {
      final p = await Geolocator.requestPermission();
      if (p == LocationPermission.deniedForever) await Geolocator.openAppSettings();
    }
    widget.data.refresh();
  }

  List<DeliveryOrder> _matches() {
    final q = _query.trim().toLowerCase();
    final digits = q.replaceAll(RegExp(r'\D'), '');
    final all = [...widget.data.activeOrders, ...widget.data.recentOrders];
    return all.where((o) {
      if (o.trackingNo.toLowerCase().contains(q)) return true;
      if (o.saleOrder.toLowerCase().contains(q)) return true;
      if (o.customerName.toLowerCase().contains(q)) return true;
      if (digits.length >= 3 && o.customerPhone.replaceAll(RegExp(r'\D'), '').contains(digits)) return true;
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.data,
      builder: (context, _) {
        final d = widget.data;
        return SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: d.refresh,
            color: SokoColors.green,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 120),
              children: [
                _header(d),
                const SizedBox(height: 18),
                _searchBar(d),
                const SizedBox(height: 18),
                if (_query.trim().isNotEmpty) ..._searchResults() else ..._home(d),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(RiderData d) {
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: SokoColors.line)),
          child: ClipOval(
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Image.asset(sokoLogoMarkAsset, fit: BoxFit.contain),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(d.profile == null ? 'Delivery Hub' : 'Delivery Hub · ${d.profile!.name}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: SokoColors.slate)),
              const Text(AppConfig.shopName, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: SokoColors.ink)),
            ],
          ),
        ),
        InkResponse(
          onTap: widget.onSeeOrders,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: SokoColors.line)),
            child: Stack(alignment: Alignment.center, children: [
              const Icon(Icons.notifications_none_rounded, color: SokoColors.ink, size: 26),
              if (d.newOrderCount > 0)
                Positioned(
                  top: 10,
                  right: 11,
                  child: Container(width: 9, height: 9, decoration: BoxDecoration(color: SokoColors.red, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1.5))),
                ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _searchBar(RiderData d) {
    return Container(
      padding: const EdgeInsets.only(left: 16, right: 6),
      height: 60,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: SokoColors.line)),
      child: Row(
        children: [
          const Icon(Icons.search, color: SokoColors.slate),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search order ID or phone…',
                border: InputBorder.none,
                isDense: true,
                hintStyle: TextStyle(color: SokoColors.slate),
              ),
            ),
          ),
          if (_query.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close, color: SokoColors.slate),
              onPressed: () => setState(() {
                _search.clear();
                _query = '';
              }),
            ),
          Material(
            color: SokoColors.ink,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: d.loading ? null : d.refresh,
              child: SizedBox(
                width: 48,
                height: 48,
                child: d.loading
                    ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.refresh_rounded, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _searchResults() {
    final m = _matches();
    return [
      Text('${m.length} result${m.length == 1 ? '' : 's'}', style: const TextStyle(fontWeight: FontWeight.w800, color: SokoColors.ink, fontSize: 16)),
      const SizedBox(height: 12),
      for (final o in m) OrderTile(order: o, onTap: o.isDelivered ? null : () => widget.onOpen(o)),
    ];
  }

  List<Widget> _home(RiderData d) {
    final activeOk = d.active?.ok ?? false;
    final current = d.current;
    return [
      if (d.active != null && !activeOk) ...[
        ErrorPanel(message: d.active!.error ?? 'Could not load orders.', onRetry: d.refresh),
        const SizedBox(height: 14),
      ],
      if (d.gpsProblem != null) ...[
        _gpsBanner(d.gpsProblem!),
        const SizedBox(height: 14),
      ],

      // Two quick tiles
      SizedBox(
        height: 150,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SokoCard(
                onTap: widget.onSeeOrders,
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Active\nDispatch', style: TextStyle(fontSize: 18, height: 1.15, fontWeight: FontWeight.w800, color: SokoColors.ink)),
                    const Spacer(),
                    Row(children: [
                      const Text('🛵', style: TextStyle(fontSize: 30)),
                      const Spacer(),
                      Text(activeOk ? '${d.activeOrders.length}' : '—',
                          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: SokoColors.ink)),
                    ]),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: SokoCard(
                color: SokoColors.greenTint,
                borderColor: SokoColors.leaf.withOpacity(0.35),
                onTap: () => openNavigation(context, AppConfig.shopLatitude, AppConfig.shopLongitude),
                padding: const EdgeInsets.all(18),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Pick-up\nPoint', style: TextStyle(fontSize: 18, height: 1.15, fontWeight: FontWeight.w800, color: SokoColors.green)),
                    Spacer(),
                    Row(children: [
                      Text('📦', style: TextStyle(fontSize: 30)),
                      Spacer(),
                      Icon(Icons.navigation_rounded, color: SokoColors.green),
                    ]),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 26),

      _sectionTitle('Current Delivery', d.activeOrders.length > 1 ? 'See all (${d.activeOrders.length})' : null, widget.onSeeOrders),
      const SizedBox(height: 12),
      if (d.active == null)
        const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(color: SokoColors.green)))
      else if (current != null)
        OrderCard(order: current, onTap: () => widget.onOpen(current))
      else if (activeOk)
        SokoCard(
          padding: const EdgeInsets.all(22),
          child: Column(children: [
            const Text('🛵', style: TextStyle(fontSize: 40)),
            const SizedBox(height: 8),
            const Text('No delivery assigned right now', style: TextStyle(fontWeight: FontWeight.w800, color: SokoColors.ink, fontSize: 15)),
            const SizedBox(height: 4),
            Text(
              d.lastUpdated == null
                  ? 'New orders show up here automatically.'
                  : 'Checked at ${TimeOfDay.fromDateTime(d.lastUpdated!).format(context)} · refreshes every minute',
              style: const TextStyle(fontSize: 12, color: SokoColors.slate),
            ),
          ]),
        ),

      // Recent Dispatches: only once the server has a history endpoint.
      if (d.history != null && !d.history!.notAvailable) ...[
        const SizedBox(height: 26),
        _sectionTitle('Recent Dispatches', null, null),
        const SizedBox(height: 12),
        if (!d.history!.ok)
          Text(d.history!.error ?? '', style: const TextStyle(color: SokoColors.red, fontSize: 13))
        else if (d.recentOrders.isEmpty)
          const Text('No completed deliveries yet.', style: TextStyle(color: SokoColors.slate, fontSize: 13))
        else
          for (final o in d.recentOrders.take(5)) OrderTile(order: o),
      ],
    ];
  }

  Widget _sectionTitle(String title, String? action, VoidCallback? onAction) {
    return Row(
      children: [
        Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: SokoColors.ink)),
        const Spacer(),
        if (action != null)
          GestureDetector(
            onTap: onAction,
            child: Text(action, style: const TextStyle(fontSize: 14, color: SokoColors.slate, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  Widget _gpsBanner(LiveStatus problem) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(color: SokoColors.redLight, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          const Icon(Icons.gps_off, color: SokoColors.red),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              problem == LiveStatus.gpsOff ? 'Phone location (GPS) is off. Customers can\'t track you.' : 'Location permission not granted.',
              style: const TextStyle(color: SokoColors.red, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(onPressed: _fixGps, child: const Text('Fix')),
        ],
      ),
    );
  }
}
