import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../config.dart';
import '../models/delivery_order.dart';
import '../services/location_hub.dart';
import '../services/location_stream_service.dart';
import '../services/odoo_service.dart';
import '../services/turn_nav.dart';
import '../widgets/common.dart';

/// "Location Tracking": live map on top, dark booking sheet below.
/// While this screen is open the phone's real GPS is streamed to Soko.
class ActiveDeliveryScreen extends StatefulWidget {
  final DeliveryOrder order;
  final OdooService odooService;

  const ActiveDeliveryScreen({super.key, required this.order, required this.odooService});

  @override
  State<ActiveDeliveryScreen> createState() => _ActiveDeliveryScreenState();
}

class _ActiveDeliveryScreenState extends State<ActiveDeliveryScreen> {
  final _locationService = LocationStreamService();
  final MapController _mapController = MapController();

  LatLng? _riderPos;
  double _heading = 0;
  double _speedKmh = 0.0;
  double? _accuracyM;
  LiveStatus _status = LiveStatus.idle;
  bool _isCompleting = false;
  bool _fitted = false;
  late DeliveryOrder _order = widget.order;
  late bool _pickupConfirmed = widget.order.riderPickupAt != null;
  bool _pickingUp = false;
  Timer? _statusPoll;
  Position? _gps; // latest phone location, for the shop-area check
  StreamSubscription<Position>? _pickupSub;
  static const _pickupHolder = 'pickup';

  // Turn-by-turn navigation (in the app, like Bolt).
  TurnNavigator? _nav;
  bool _navOn = false;
  bool _follow = true;
  double _mapRotation = 0;
  final _sheetCtl = DraggableScrollableController();

  /// Before the shop sends the order out the rider rides to the shop,
  /// afterwards to the customer's pin.
  LatLng get _navDest => _dispatched ? LatLng(order.destLat!, order.destLng!) : LatLng(ShopArea.lat, ShopArea.lng);

  DeliveryOrder get order => _order;

  /// The shop has sent the order out (POS "Send to dispatch"). Only then does
  /// the rider get the customer's phone and can mark it delivered.
  bool get _dispatched => order.isOutForDelivery || order.isDelivered;

  @override
  void initState() {
    super.initState();
    if (order.hasLocation) _startTracking();
    if (!_dispatched) {
      _statusPoll = Timer.periodic(const Duration(seconds: 15), (_) => _refreshOrder());
    }
    if (!_pickupConfirmed && !_dispatched) _watchShopArea();
  }

  /// GPS while the rider is on the way to the shop, so "Picked Up" unlocks
  /// as soon as they are inside the shop area.
  Future<void> _watchShopArea() async {
    _gps = LocationHub.instance.last;
    _pickupSub = LocationHub.instance.positions.listen((p) {
      if (mounted) setState(() => _gps = p);
    }, onError: (_) {});
    await LocationHub.instance.hold(_pickupHolder);
    if (_gps == null) {
      final last = await Geolocator.getLastKnownPosition();
      if (mounted && last != null && _gps == null) setState(() => _gps = last);
    }
  }

  void _stopWatchingShopArea() {
    _pickupSub?.cancel();
    _pickupSub = null;
    LocationHub.instance.release(_pickupHolder);
  }

  /// Metres from the shop, or null while the phone has no location yet.
  double? get _metresFromShop {
    final lat = _gps?.latitude ?? _riderPos?.latitude;
    final lng = _gps?.longitude ?? _riderPos?.longitude;
    if (lat == null || lng == null) return null;
    return Geolocator.distanceBetween(lat, lng, ShopArea.lat, ShopArea.lng);
  }

  bool get _insideShopArea {
    final d = _metresFromShop;
    return d != null && d <= ShopArea.radiusM;
  }

  String get _pickupLabel {
    if (_pickupConfirmed) return 'Waiting for shop…';
    final d = _metresFromShop;
    if (d == null) return 'Finding GPS…';
    if (d <= ShopArea.radiusM) return 'Picked Up';
    return d >= 1000 ? 'Shop ${(d / 1000).toStringAsFixed(1)} km away' : 'Shop ${d.round()} m away';
  }

  /// Re-read the order from Soko until the shop dispatches it.
  Future<void> _refreshOrder() async {
    final res = await widget.odooService.getAssignedDeliveries();
    if (!mounted || !res.ok) return;
    final fresh = res.orders.where((o) => o.id == order.id).toList();
    if (fresh.isEmpty) return;
    final wasDispatched = _dispatched;
    setState(() {
      _order = fresh.first;
      if (_order.riderPickupAt != null) _pickupConfirmed = true;
    });
    if (!wasDispatched && _dispatched) {
      _statusPoll?.cancel();
      HapticFeedback.mediumImpact();
      if (_navOn) {
        _startNav(); // now to the customer
      } else {
        _nav?.dispose();
        _nav = null;
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('The shop has sent this order out. Customer phone unlocked. Navigate to the customer.'),
      ));
    }
  }

  Future<void> _startTracking() async {
    await _locationService.startStreaming(
      wsUrl: AppConfig.wsStreamUrl,
      trackingToken: order.trackingNo,
      onStatus: (s) {
        if (mounted) setState(() => _status = s);
      },
      onLocationUpdate: (Position pos) {
        if (!mounted) return;
        setState(() {
          _riderPos = LatLng(pos.latitude, pos.longitude);
          if (pos.heading >= 0 && pos.speed > 1) _heading = pos.heading;
          _speedKmh = pos.speed < 0 ? 0 : pos.speed * 3.6;
          _accuracyM = pos.accuracy;
        });
        if (_nav != null) _nav!.update(LatLng(pos.latitude, pos.longitude), pos.accuracy);
        if (_navOn) {
          if (_nav?.progress?.arrived == true) {
            _stopNav(arrived: true);
          } else {
            _followRider();
          }
        } else if (!_fitted) {
          _fitBoth();
        }
      },
    );
  }

  // ---------------- Navigation ----------------

  Future<void> _startNav() async {
    final from = _riderPos;
    if (from == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Waiting for GPS. Try again in a moment.')));
      return;
    }
    _nav?.dispose();
    final nav = TurnNavigator(destination: _navDest, onChanged: () {
      if (mounted) setState(() {});
    });
    setState(() {
      _nav = nav;
      _navOn = true;
      _follow = true;
    });
    try {
      WakelockPlus.enable();
    } catch (_) {}
    try {
      _sheetCtl.animateTo(0.2, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    } catch (_) {}
    _followRider();
    final ok = await nav.load(from);
    if (!mounted || _nav != nav) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(nav.error ?? 'Could not get the road route.'),
        action: SnackBarAction(label: 'Google Maps', onPressed: _openGoogle),
      ));
    }
  }

  void _stopNav({bool arrived = false}) {
    if (!_navOn) return;
    _nav?.dispose(); // stops the voice
    setState(() {
      _nav = null;
      _navOn = false;
      _follow = true;
    });
    try {
      WakelockPlus.disable();
    } catch (_) {}
    try {
      _mapController.rotate(0);
    } catch (_) {}
    _mapRotation = 0;
    _fitted = false;
    _fitBoth();
    try {
      _sheetCtl.animateTo(0.56, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    } catch (_) {}
    if (arrived && mounted) {
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_dispatched ? 'You have arrived. Hand over the order and tap Mark Delivered.' : 'You are at the shop. Tap Picked Up.'),
      ));
    }
  }

  void _followRider() {
    if (!_navOn || !_follow || _riderPos == null) return;
    try {
      // Heading up, like Bolt (only while moving, so the map does not spin).
      final rot = _speedKmh > 4 ? -_heading : _mapRotation;
      _mapController.moveAndRotate(_riderPos!, 17.5, rot);
      _mapRotation = rot;
    } catch (_) {}
  }

  void _openGoogle() {
    final d = _navDest;
    openNavigation(context, d.latitude, d.longitude);
  }

  void _fitBoth() {
    if (_riderPos == null || !order.hasLocation) return;
    try {
      _mapController.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds(_riderPos!, LatLng(order.destLat!, order.destLng!)),
        padding: EdgeInsets.fromLTRB(60, 110, 60, MediaQuery.of(context).size.height * 0.5),
      ));
      _fitted = true;
    } catch (_) {
      // Map not laid out yet; next fix will try again.
    }
  }

  Future<void> _retryPermission() async {
    if (_status == LiveStatus.gpsOff) {
      await Geolocator.openLocationSettings();
    } else if (await Geolocator.checkPermission() == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
    }
    _locationService.stopStreaming();
    await _startTracking();
  }

  Future<void> _confirmPickup() async {
    setState(() => _pickingUp = true);
    final p = _gps;
    final error = await widget.odooService.markPickedUp(order.trackingNo,
        lat: p?.latitude ?? _riderPos?.latitude, lng: p?.longitude ?? _riderPos?.longitude, accuracy: p?.accuracy ?? _accuracyM);
    if (!mounted) return;
    setState(() {
      _pickingUp = false;
      if (error == null) _pickupConfirmed = true;
    });
    if (error == null) _stopWatchingShopArea();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error ?? 'Pick-up confirmed. Waiting for the shop to send the order out.'),
    ));
    _refreshOrder();
  }

  Future<void> _completeDelivery() async {
    // 1. Ask Odoo to send the customer their delivery code.
    setState(() => _isCompleting = true);
    var result = await widget.odooService.markOrderDelivered(order.trackingNo);
    if (!mounted) return;
    // 2. Rider types the code the customer reads out.
    if (result.needCode) {
      setState(() => _isCompleting = false);
      final done = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _DeliveryCodeDialog(
          trackingNo: order.trackingNo,
          customerName: order.customerName,
          firstMessage: result.error ?? '',
          submit: (code) => widget.odooService.markOrderDelivered(order.trackingNo, code: code),
          resend: () => widget.odooService.markOrderDelivered(order.trackingNo, resend: true),
        ),
      );
      if (!mounted || done != true) return;
      result = const DeliverResult();
    }
    final error = result.error;

    if (error == null) {
      _locationService.stopStreaming();
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delivery completed'),
          content: Text('Order ${order.trackingNo} is now marked Delivered in Soko.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } else {
      // Keep tracking running: the delivery is not finished on the server.
      setState(() => _isCompleting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  void dispose() {
    _nav?.dispose();
    if (_navOn) {
      try {
        WakelockPlus.disable();
      } catch (_) {}
    }
    _statusPoll?.cancel();
    _stopWatchingShopArea();
    _locationService.stopStreaming();
    super.dispose();
  }

  ({Color color, String text}) get _statusInfo {
    switch (_status) {
      case LiveStatus.live:
        return (color: const Color(0xFF7BD66A), text: 'Live · customer can see you');
      case LiveStatus.reconnecting:
        return (color: Colors.orange, text: 'Connection lost, retrying…');
      case LiveStatus.gpsOff:
        return (color: const Color(0xFFF87171), text: 'Phone GPS is off');
      case LiveStatus.permissionDenied:
        return (color: const Color(0xFFF87171), text: 'Location permission denied');
      case LiveStatus.connecting:
      case LiveStatus.idle:
        return (color: Colors.orange, text: 'Getting GPS fix…');
    }
  }

  /// Straight-line km from the rider to the customer (not road distance).
  double? get _kmToGo {
    if (_riderPos == null || !order.hasLocation) return null;
    return const Distance().as(LengthUnit.Meter, _riderPos!, LatLng(order.destLat!, order.destLng!)) / 1000;
  }

  @override
  Widget build(BuildContext context) {
    if (!order.hasLocation) return _noLocation();

    final dest = LatLng(order.destLat!, order.destLng!);
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F0),
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: dest,
                initialZoom: 15,
                onMapReady: () {
                  if (_riderPos != null) _fitBoth();
                },
                onPositionChanged: (camera, hasGesture) {
                  _mapRotation = camera.rotation;
                  if (hasGesture && _navOn && _follow) setState(() => _follow = false);
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'ke.co.sokoexpressmtaani.rider_app',
                ),
                if (_nav?.route != null)
                  PolylineLayer(polylines: [
                    Polyline(points: _nav!.route!.path, strokeWidth: 9, color: Colors.white),
                    Polyline(points: _nav!.route!.path, strokeWidth: 6, color: const Color(0xFF1A73E8)),
                  ])
                else if (_riderPos != null)
                  PolylineLayer(polylines: [
                    Polyline(points: [_riderPos!, _navOn ? _navDest : dest], strokeWidth: 5, color: SokoColors.ink.withOpacity(0.85)),
                  ]),
                MarkerLayer(
                  markers: [
                    if (!_dispatched)
                      Marker(
                        point: LatLng(ShopArea.lat, ShopArea.lng),
                        width: 38,
                        height: 38,
                        child: Container(
                          decoration: BoxDecoration(
                            color: SokoColors.ink,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                          ),
                          child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 18),
                        ),
                      ),
                    Marker(
                      point: dest,
                      width: 34,
                      height: 34,
                      child: Container(
                        decoration: BoxDecoration(
                          color: SokoColors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 5),
                          boxShadow: [BoxShadow(color: SokoColors.green.withOpacity(0.45), blurRadius: 12, spreadRadius: 2)],
                        ),
                      ),
                    ),
                    if (_riderPos != null)
                      Marker(
                        point: _riderPos!,
                        width: 48,
                        height: 48,
                        child: Container(
                          decoration: BoxDecoration(
                            color: SokoColors.ink,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 10)],
                          ),
                          child: Transform.rotate(
                            angle: (_heading + _mapRotation) * math.pi / 180,
                            child: const Icon(Icons.navigation, color: Colors.white, size: 20),
                          ),
                        ),
                      ),
                  ],
                ),
                const RichAttributionWidget(
                  alignment: AttributionAlignment.bottomLeft,
                  attributions: [TextSourceAttribution('OpenStreetMap contributors')],
                ),
              ],
            ),
          ),

          // Top bar (turn banner while navigating)
          if (_navOn) SafeArea(child: _navBanner()) else SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  _roundButton(Icons.chevron_left, () => Navigator.pop(context)),
                  const Expanded(
                    child: Text('Location Tracking',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: SokoColors.ink)),
                  ),
                  _roundButton(Icons.center_focus_strong, () {
                    _fitted = false;
                    _fitBoth();
                  }),
                ],
              ),
            ),
          ),

          if (_navOn && !_follow)
            Positioned(
              right: 16,
              bottom: MediaQuery.of(context).size.height * 0.22 + 12,
              child: FloatingActionButton.extended(
                heroTag: 'recentre',
                backgroundColor: Colors.white,
                foregroundColor: SokoColors.ink,
                icon: const Icon(Icons.navigation_rounded),
                label: const Text('Re-centre', style: TextStyle(fontWeight: FontWeight.w800)),
                onPressed: () {
                  setState(() => _follow = true);
                  _followRider();
                },
              ),
            ),

          DraggableScrollableSheet(
            controller: _sheetCtl,
            initialChildSize: 0.56,
            minChildSize: 0.2,
            maxChildSize: 0.92,
            snap: true,
            builder: (context, scroll) => Container(
              decoration: const BoxDecoration(
                color: SokoColors.sheet,
                borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
              ),
              child: ListView(
                controller: scroll,
                padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + MediaQuery.of(context).padding.bottom),
                children: _sheet(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _sheet() {
    final info = _statusInfo;
    final blocked = _status == LiveStatus.gpsOff || _status == LiveStatus.permissionDenied;
    final kmToGo = _kmToGo;
    const label = TextStyle(color: Color(0xFF9CA3AF), fontSize: 13);
    const value = TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800);
    const divider = Divider(color: SokoColors.sheetLine, height: 32);

    return [
      Center(
        child: Container(width: 44, height: 5, decoration: BoxDecoration(color: const Color(0xFF4B5563), borderRadius: BorderRadius.circular(3))),
      ),
      const SizedBox(height: 18),
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Booking ID:', style: label),
              Text(order.trackingNo, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            const Text('Status', style: label),
            const SizedBox(height: 4),
            StatusPill(order.statusLabel, dark: true),
          ]),
        ],
      ),
      const SizedBox(height: 20),
      ProgressSteps(step: order.progressStep, dark: true),
      const SizedBox(height: 16),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(order.createdAt != null ? 'Created, ${formatDate(order.createdAt!)}' : 'Pick-up', style: label),
              const Text(AppConfig.shopName, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
            ]),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(kmToGo != null ? '${kmToGo.toStringAsFixed(1)} km away (straight line)' : 'Drop-off', style: label, textAlign: TextAlign.end),
              Text(order.deliveryArea.isEmpty ? 'Pinned location' : order.deliveryArea,
                  textAlign: TextAlign.end, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
            ]),
          ),
        ],
      ),
      divider,
      _pair('Customer', order.customerName.isEmpty ? 'Not provided' : order.customerName, 'Order Total', formatKsh(order.amountTotal, decimals: true),
          label, value, rightGreen: true),
      const SizedBox(height: 16),
      _pair('Trip Distance', order.distanceKm == null ? '—' : '${order.distanceKm!.toStringAsFixed(1)} km', 'Rider Payout',
          formatKsh(order.riderPayout, decimals: true), label, value,
          rightGreen: true),
      divider,

      // Live GPS status
      Row(children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: info.color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(child: Text(info.text, style: TextStyle(color: info.color, fontWeight: FontWeight.w700, fontSize: 14))),
        if (_riderPos != null) Text('${_speedKmh.toStringAsFixed(0)} km/h', style: value),
      ]),
      if (_accuracyM != null && _accuracyM! > 50)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Weak GPS signal (±${_accuracyM!.toStringAsFixed(0)} m)', style: const TextStyle(fontSize: 12, color: Colors.orange)),
        ),
      if (blocked) ...[
        const SizedBox(height: 10),
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54)),
          onPressed: _retryPermission,
          child: Text(_status == LiveStatus.gpsOff ? 'Turn on GPS' : 'Allow location'),
        ),
      ],
      const SizedBox(height: 18),
      Row(children: [
        Expanded(
          child: SizedBox(
            height: 52,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFF4B5563)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              icon: Icon(_navOn ? Icons.close_rounded : Icons.navigation_rounded),
              label: Text(_navOn ? 'Stop' : (_dispatched ? 'Navigate' : 'To Shop'), style: const TextStyle(fontWeight: FontWeight.w700)),
              onPressed: () => _navOn ? _stopNav() : _startNav(),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 52,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: SokoColors.green,
                foregroundColor: Colors.white,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: (_isCompleting || _pickingUp || (!_dispatched && (_pickupConfirmed || !_insideShopArea)))
                  ? null
                  : (_dispatched ? _completeDelivery : _confirmPickup),
              child: (_isCompleting || _pickingUp)
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text(_dispatched ? 'Mark Delivered' : _pickupLabel,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            ),
          ),
        ),
      ]),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: Colors.white70, padding: EdgeInsets.zero),
          icon: const Icon(Icons.map_outlined, size: 18),
          label: const Text('Open in Google Maps instead'),
          onPressed: _openGoogle,
        ),
      ),
      if (!_dispatched && !_pickupConfirmed)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _insideShopArea
                ? 'You are at the shop. Collect the parcel, then tap Picked Up.'
                : 'Picked Up unlocks when you are within ${ShopArea.radiusM.round()} m of the shop.',
            style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12.5),
          ),
        ),
      const SizedBox(height: 22),

      // Customer contact footer
      Row(children: [
        CircleAvatar(
          radius: 26,
          backgroundColor: SokoColors.green,
          child: Text(initials(order.customerName), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(order.customerName.isEmpty ? 'Customer' : order.customerName,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16), overflow: TextOverflow.ellipsis),
            Text(
                order.phoneHidden
                    ? 'Phone shown once the shop sends the order out'
                    : (order.customerPhone.isEmpty ? 'No phone on order' : 'Customer · ${order.customerPhone}'),
                style: label),
          ]),
        ),
        _circle(Icons.call, SokoColors.green, Colors.white,
            order.customerPhone.isEmpty ? null : () => callPhone(context, order.customerPhone)),
        const SizedBox(width: 10),
        _circle(Icons.chat_bubble_outline, Colors.white, SokoColors.ink,
            order.customerPhone.isEmpty
                ? null
                : () => smsPhone(context, order.customerPhone,
                    body: 'Hi, this is your Soko Express Mtaani rider with order ${order.trackingNo}. ')),
      ]),
    ];
  }

  /// Bolt-style banner: next turn, distance to it, then the one after.
  Widget _navBanner() {
    final nav = _nav;
    final p = nav?.progress;
    final next = p?.next;
    final now = DateTime.now().add(Duration(seconds: (p?.remainingS ?? 0).round()));
    String two(int v) => v.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Material(
          color: const Color(0xFF0F7A3D),
          elevation: 6,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
            child: (nav == null || nav.loading && p == null)
                ? const Row(children: [
                    SizedBox(width: 26, height: 26, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3)),
                    SizedBox(width: 14),
                    Expanded(child: Text('Finding the best road…', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700))),
                  ])
                : next == null
                    ? Row(children: [
                        const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 30),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Text(nav.error ?? 'No route yet.',
                                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700))),
                        TextButton(
                          onPressed: _startNav,
                          child: const Text('Retry', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                        ),
                      ])
                    : Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                        Icon(next.icon, color: Colors.white, size: 54),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(next.isArrive && p!.toNextM < 30 ? 'Arrived' : navDistance(p!.toNextM),
                                style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900, height: 1.05)),
                            const SizedBox(height: 2),
                            Text(next.text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                          ]),
                        ),
                        IconButton(
                          tooltip: nav.muted ? 'Voice on' : 'Mute voice',
                          onPressed: () => setState(() => nav.muted = !nav.muted),
                          icon: Icon(nav.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: Colors.white, size: 28),
                        ),
                      ]),
          ),
        ),
        if (p != null && next != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              if (p.after != null && p.toNextM < 400 && !next.isArrive)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(color: const Color(0xFF0B5C2E), borderRadius: BorderRadius.circular(14)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Then ', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                    Icon(p.after!.icon, color: Colors.white, size: 20),
                  ]),
                ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                ),
                child: Text(
                  '${navDistance(p.remainingM)} · ${navDuration(p.remainingS)} · ${two(now.hour)}:${two(now.minute)}',
                  style: const TextStyle(color: SokoColors.ink, fontWeight: FontWeight.w800),
                ),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _pair(String l1, String v1, String l2, String v2, TextStyle label, TextStyle value, {bool rightGreen = false}) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l1, style: label),
          const SizedBox(height: 2),
          Text(v1, style: value, overflow: TextOverflow.ellipsis),
        ]),
      ),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l2, style: label),
          const SizedBox(height: 2),
          Text(v2, style: rightGreen ? value.copyWith(color: const Color(0xFF7BD66A)) : value),
        ]),
      ),
    ]);
  }

  Widget _circle(IconData icon, Color bg, Color fg, VoidCallback? onTap) => Material(
        color: onTap == null ? bg.withOpacity(0.35) : bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 54, height: 54, child: Icon(icon, color: fg)),
        ),
      );

  Widget _roundButton(IconData icon, VoidCallback onTap) => Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 3,
        shadowColor: Colors.black26,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 48, height: 48, child: Icon(icon, color: SokoColors.ink)),
        ),
      );

  Widget _noLocation() {
    return Scaffold(
      appBar: AppBar(title: Text(order.trackingNo)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.location_off, size: 56, color: SokoColors.red),
            const SizedBox(height: 12),
            const Text('This order has no delivery location',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: SokoColors.ink)),
            const SizedBox(height: 8),
            const Text(
              'Every website order should have a map pin. Ask Soko dispatch to check this order before you start.',
              textAlign: TextAlign.center,
              style: TextStyle(color: SokoColors.slate),
            ),
            if (order.customerPhone.isNotEmpty) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                icon: const Icon(Icons.call),
                label: const Text('Call customer'),
                onPressed: () => callPhone(context, order.customerPhone),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}


/// Rider enters the 4-digit code the customer sees in their app.
class _DeliveryCodeDialog extends StatefulWidget {
  final String trackingNo;
  final String customerName;
  final String firstMessage;
  final Future<DeliverResult> Function(String code) submit;
  final Future<DeliverResult> Function() resend;
  const _DeliveryCodeDialog({
    required this.trackingNo,
    required this.customerName,
    required this.firstMessage,
    required this.submit,
    required this.resend,
  });
  @override
  State<_DeliveryCodeDialog> createState() => _DeliveryCodeDialogState();
}

class _DeliveryCodeDialogState extends State<_DeliveryCodeDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  late String _info = widget.firstMessage;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final c = _code.text.trim();
    if (c.length != 4) {
      setState(() => _error = 'Enter the 4-digit code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await widget.submit(c);
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = false;
      _error = r.error;
      _code.clear();
    });
  }

  Future<void> _resend() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await widget.resend();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _info = r.needCode ? 'New code sent to the customer.' : (r.error ?? '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final who = widget.customerName.isEmpty ? 'the customer' : widget.customerName;
    return AlertDialog(
      title: const Text('Delivery code'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Ask $who for the 4-digit code in their Soko app (or on their order).'),
        if (_info.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_info, style: const TextStyle(fontSize: 13, color: Colors.black54)),
        ],
        const SizedBox(height: 14),
        TextField(
          controller: _code,
          autofocus: true,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          maxLength: 4,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 14),
          decoration: const InputDecoration(counterText: '', hintText: '••••', border: OutlineInputBorder()),
          onSubmitted: (_) => _confirm(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.w600)),
        ],
      ]),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(onPressed: _busy ? null : _resend, child: const Text('Resend code')),
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Confirm delivered'),
        ),
      ],
    );
  }
}
