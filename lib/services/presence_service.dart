import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'location_hub.dart';
import 'location_stream_service.dart';
import 'odoo_service.dart';

/// Rider's Online/Offline switch for dispatch.
///
/// While Online: GPS runs in the light "online" mode, Soko gets the rider's
/// location every minute (for distance-from-shop), and the app checks for
/// delivery requests every 15 seconds. Push notifications (Firebase) wake the
/// phone even when the app is closed.
class PresenceService extends ChangeNotifier {
  PresenceService(this.service);
  final OdooService service;

  static const _holder = 'online';
  static const _prefKey = 'rider_online';

  bool online = false;
  bool busy = false; // switching
  String? error;
  double? distanceFromShopKm;
  DateTime? lastHeartbeat;
  List<DispatchOffer> offers = const [];

  /// Called when a new request arrives (shell opens the request screen).
  void Function(DispatchOffer offer)? onNewOffer;

  Timer? _heartbeatTimer;
  Timer? _offerTimer;
  StreamSubscription<Position>? _posSub;
  final Set<int> _announced = {};
  bool _checking = false;

  /// Restore the switch after the app restarts.
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_prefKey) == true) {
      await goOnline(silentFail: true);
    } else {
      // Even offline, a request might have been sent manually.
      unawaited(checkOffers());
    }
  }

  Future<void> toggle() => online ? goOffline() : goOnline();

  Future<void> goOnline({bool silentFail = false}) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();

    final blocked = await LocationStreamService.ensurePermission();
    if (blocked != null) {
      busy = false;
      error = blocked == LiveStatus.gpsOff
          ? 'Turn on your phone\'s location (GPS) to go online.'
          : 'Allow location so Soko can send you nearby orders.';
      notifyListeners();
      return;
    }

    await LocationHub.instance.hold(_holder);
    Position? pos = LocationHub.instance.last;
    pos ??= await Geolocator.getLastKnownPosition();

    final err = await service.setOnline(true, lat: pos?.latitude, lng: pos?.longitude);
    busy = false;
    if (err != null) {
      await LocationHub.instance.release(_holder);
      error = silentFail ? null : err;
      online = false;
      notifyListeners();
      return;
    }
    online = true;
    (await SharedPreferences.getInstance()).setBool(_prefKey, true);
    _startTimers();
    notifyListeners();
    unawaited(_sendHeartbeat());
    unawaited(checkOffers());
  }

  Future<void> goOffline() async {
    if (busy) return;
    busy = true;
    notifyListeners();
    final err = await service.setOnline(false);
    _stopTimers();
    await LocationHub.instance.release(_holder);
    online = false;
    busy = false;
    error = err;
    offers = const [];
    (await SharedPreferences.getInstance()).setBool(_prefKey, false);
    notifyListeners();
  }

  void _startTimers() {
    _stopTimers();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 60), (_) => _sendHeartbeat());
    _offerTimer = Timer.periodic(const Duration(seconds: 15), (_) => checkOffers());
    // Also report straight away when the rider has moved a lot.
    Position? lastSent;
    _posSub = LocationHub.instance.positions.listen((p) {
      if (lastSent == null ||
          Geolocator.distanceBetween(lastSent!.latitude, lastSent!.longitude, p.latitude, p.longitude) > 300) {
        lastSent = p;
        _sendHeartbeat();
      }
    }, onError: (_) {});
  }

  void _stopTimers() {
    _heartbeatTimer?.cancel();
    _offerTimer?.cancel();
    _posSub?.cancel();
    _heartbeatTimer = null;
    _offerTimer = null;
    _posSub = null;
  }

  Future<void> _sendHeartbeat() async {
    final p = LocationHub.instance.last;
    final res = await service.heartbeat(lat: p?.latitude, lng: p?.longitude, accuracy: p?.accuracy);
    if (res == null) return;
    lastHeartbeat = DateTime.now();
    final d = res['distance_from_shop_km'];
    distanceFromShopKm = d is num ? d.toDouble() : null;
    if (res['online'] == false && online) {
      // Server says offline (e.g. admin reset): reflect it.
      online = false;
      _stopTimers();
      await LocationHub.instance.release(_holder);
    }
    final pending = res['pending_offers'];
    if (pending is int && pending > 0) {
      unawaited(checkOffers());
    }
    notifyListeners();
  }

  /// Ask Soko for requests waiting for this rider. Safe to call any time
  /// (push notification arrived, app resumed, timer).
  Future<void> checkOffers() async {
    if (_checking) return;
    _checking = true;
    try {
      final list = await service.getOffers();
      if (list == null) return;
      offers = list.where((o) => o.secondsLeft > 0).toList();
      notifyListeners();
      for (final o in offers) {
        if (_announced.add(o.id)) onNewOffer?.call(o);
      }
    } finally {
      _checking = false;
    }
  }

  /// Accept/decline. Returns null on success, or a message to show.
  Future<String?> respond(DispatchOffer offer, bool accept, {String? reason}) async {
    final err = await service.respondOffer(offer.id, accept, reason: reason);
    offers = offers.where((o) => o.id != offer.id).toList();
    notifyListeners();
    return err;
  }

  @override
  void dispose() {
    _stopTimers();
    super.dispose();
  }
}
