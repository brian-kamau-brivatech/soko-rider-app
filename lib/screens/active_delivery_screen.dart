import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../config.dart';
import '../models/delivery_order.dart';
import '../services/location_stream_service.dart';
import '../services/odoo_service.dart';
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
  late bool _pickedUp = widget.order.progressStep >= 2;
  bool _pickingUp = false;

  DeliveryOrder get order => widget.order;

  @override
  void initState() {
    super.initState();
    if (order.hasLocation) _startTracking();
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
        if (!_fitted) _fitBoth();
      },
    );
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
    final error = await widget.odooService.markPickedUp(order.trackingNo);
    if (!mounted) return;
    setState(() {
      _pickingUp = false;
      if (error == null) _pickedUp = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error ?? 'Picked up. The customer now sees you are on the way.'),
    ));
  }

  Future<void> _completeDelivery() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm delivery'),
        content: Text('Mark ${order.trackingNo} as delivered${order.customerName.isEmpty ? '' : ' to ${order.customerName}'}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, delivered')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isCompleting = true);
    final error = await widget.odooService.markOrderDelivered(order.trackingNo);
    if (!mounted) return;

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
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'ke.co.sokoexpressmtaani.rider_app',
                ),
                if (_riderPos != null)
                  PolylineLayer(polylines: [
                    Polyline(points: [_riderPos!, dest], strokeWidth: 5, color: SokoColors.ink.withOpacity(0.85)),
                  ]),
                MarkerLayer(
                  markers: [
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
                            angle: _heading * math.pi / 180,
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

          // Top bar
          SafeArea(
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

          DraggableScrollableSheet(
            initialChildSize: 0.56,
            minChildSize: 0.3,
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
      ProgressSteps(step: _pickedUp && order.progressStep < 2 ? 2 : order.progressStep, dark: true),
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
              icon: const Icon(Icons.navigation_rounded),
              label: Text(_pickedUp ? 'Navigate' : 'To Shop', style: const TextStyle(fontWeight: FontWeight.w700)),
              onPressed: () => _pickedUp
                  ? openNavigation(context, order.destLat!, order.destLng!)
                  : openNavigation(context, AppConfig.shopLatitude, AppConfig.shopLongitude),
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
              onPressed: (_isCompleting || _pickingUp) ? null : (_pickedUp ? _completeDelivery : _confirmPickup),
              child: (_isCompleting || _pickingUp)
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text(_pickedUp ? 'Mark Delivered' : 'Picked Up',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            ),
          ),
        ),
      ]),
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
            Text(order.customerPhone.isEmpty ? 'No phone on order' : 'Customer · ${order.customerPhone}', style: label),
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
