import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/delivery_order.dart';
import 'location_stream_service.dart';
import 'odoo_service.dart';

/// One place that loads everything the home screens show, so the tabs agree.
/// All of it comes from the Soko server (or the phone's own GPS status).
class RiderData extends ChangeNotifier {
  final OdooService service;
  RiderData(this.service);

  RiderProfile? profile;
  OrdersResult? active;
  OrdersResult? history;
  LiveStatus? gpsProblem; // null = ready
  Set<int> seenIds = {};
  bool loading = false;
  DateTime? lastUpdated;
  Timer? _timer;

  List<DeliveryOrder> get activeOrders => active?.orders ?? const [];
  List<DeliveryOrder> get recentOrders => history?.orders ?? const [];
  DeliveryOrder? get current => activeOrders.isEmpty ? null : activeOrders.first;

  /// Active orders the rider has not opened the list for yet.
  int get newOrderCount => activeOrders.where((o) => !seenIds.contains(o.id)).length;

  void startAutoRefresh() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => refresh());
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    notifyListeners();
    final r = await Future.wait<Object?>([
      service.getSavedProfile(),
      service.getAssignedDeliveries(),
      service.getRecentDeliveries(),
      LocationStreamService.ensurePermission(ask: false),
      service.getSeenOrderIds(),
    ]);
    profile = r[0] as RiderProfile?;
    active = r[1] as OrdersResult;
    history = r[2] as OrdersResult;
    gpsProblem = r[3] as LiveStatus?;
    seenIds = r[4] as Set<int>;
    loading = false;
    lastUpdated = DateTime.now();
    notifyListeners();
  }

  Future<void> markAllSeen() async {
    seenIds = {...seenIds, ...activeOrders.map((o) => o.id)};
    await service.markOrdersSeen(seenIds);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
