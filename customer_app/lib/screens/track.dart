import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'pay.dart';

class TrackScreen extends StatefulWidget {
  final ShopOrder order;
  const TrackScreen({super.key, required this.order});
  @override
  State<TrackScreen> createState() => _TrackScreenState();
}

class _TrackScreenState extends State<TrackScreen> {
  late ShopOrder _o;
  final _map = MapController();
  Timer? _poll;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _o = widget.order;
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final o = await ShopApi.status(_o.id, _o.token);
      if (!mounted) return;
      final hadRider = _o.riderLat != null;
      setState(() => _o = o);
      if (o.delivered || o.cancelled) _poll?.cancel();
      if (_ready && !hadRider && o.riderLat != null) _fit();
    } catch (_) {}
  }

  LatLng get _dest {
    final c = AppStore.instance.catalog;
    return LatLng(_o.destLat ?? c?.shopLat ?? -0.303099, _o.destLng ?? c?.shopLng ?? 36.080026);
  }

  LatLng? get _rider => (_o.riderLat != null && _o.riderLng != null) ? LatLng(_o.riderLat!, _o.riderLng!) : null;

  void _fit() {
    final r = _rider;
    if (r == null) return;
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints([_dest, r]),
      padding: const EdgeInsets.fromLTRB(60, 120, 60, 380),
    ));
  }

  Future<void> _call() async {
    final uri = Uri(scheme: 'tel', path: _o.riderPhone);
    if (!await launchUrl(uri) && mounted) toast(context, 'Could not open the phone app.');
  }

  @override
  Widget build(BuildContext context) {
    final rider = _rider;
    final steps = ['Paid', 'Rider', 'Packed', 'On the way', 'Delivered'];
    final step = _o.step;
    String title;
    String subtitle;
    if (_o.cancelled) {
      title = 'Order cancelled';
      subtitle = 'Contact the shop if this is a mistake.';
    } else if (_o.delivered) {
      title = 'Delivered. Enjoy!';
      subtitle = 'Thank you for shopping with us.';
    } else if (step == 3) {
      title = 'Your rider is on the way';
      subtitle = rider != null ? 'Live location from your rider' : 'Your order has left the shop';
    } else if (step == 2) {
      title = _o.status == 'preparing' ? 'Packing your order' : 'Rider assigned';
      subtitle = 'Your rider is collecting your order from the shop';
    } else if (step == 1) {
      title = 'Payment received';
      subtitle = 'The shop is preparing your order';
    } else {
      title = 'Waiting for payment';
      subtitle = 'Pay with M-Pesa to send your order to the shop';
    }

    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _dest,
              initialZoom: 15,
              onMapReady: () {
                _ready = true;
                _fit();
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'ke.co.sokoexpressmtaani.soko_shop',
              ),
              if (rider != null)
                PolylineLayer(polylines: [
                  Polyline(points: [rider, _dest], strokeWidth: 4, color: C.green.withValues(alpha: 0.8)),
                ]),
              MarkerLayer(markers: [
                Marker(
                  point: _dest,
                  width: 44,
                  height: 44,
                  alignment: Alignment.topCenter,
                  child: const Icon(Icons.location_on, color: C.green, size: 44),
                ),
                if (rider != null)
                  Marker(
                    point: rider,
                    width: 48,
                    height: 48,
                    child: Container(
                      decoration: BoxDecoration(
                        color: C.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10)],
                      ),
                      child: const Icon(Icons.delivery_dining_rounded, color: Colors.white, size: 24),
                    ),
                  ),
              ]),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 12, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const BackSquare(),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                color: Colors.white70,
                child: const Text('© OpenStreetMap contributors', style: TextStyle(fontSize: 10, color: C.muted)),
              ),
            ]),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + MediaQuery.of(context).padding.bottom),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              boxShadow: [BoxShadow(color: Color(0x1A000000), blurRadius: 24, offset: Offset(0, -6))],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(
                child: Container(width: 40, height: 5, decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(3))),
              ),
              const SizedBox(height: 12),
              Text('${_o.name}${_o.trackingNo.isNotEmpty ? ' · ${_o.trackingNo}' : ''}'.toUpperCase(),
                  style: const TextStyle(fontSize: 12.5, letterSpacing: 1.2, color: C.accent)),
              const SizedBox(height: 2),
              Text(title, style: head(22)),
              Text(subtitle, style: const TextStyle(fontSize: 13.5, color: C.muted)),
              const SizedBox(height: 14),
              if (!_o.cancelled)
                Row(children: [
                  for (var i = 0; i < steps.length; i++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: i < steps.length - 1 ? 4 : 0),
                        child: Column(children: [
                          Container(
                            height: 5,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(3),
                              color: i < step ? C.green : (i == step && step > 0 ? C.accent : C.line),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(steps[i],
                              style: TextStyle(
                                fontSize: 10.5,
                                color: i == step ? C.ink : C.muted,
                                fontWeight: i == step ? FontWeight.w700 : FontWeight.w400,
                              )),
                        ]),
                      ),
                    ),
                ]),
              const SizedBox(height: 14),
              if (_o.riderName.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.line)),
                  child: Row(children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: const BoxDecoration(color: C.greenLight, shape: BoxShape.circle),
                      child: const Icon(Icons.person_outline_rounded, color: C.green),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_o.riderName, style: head(15, w: FontWeight.w600)),
                        const Text('Your delivery rider', style: TextStyle(fontSize: 12.5, color: C.muted)),
                      ]),
                    ),
                    if (_o.riderPhone.isNotEmpty)
                      Material(
                        color: C.green,
                        shape: const CircleBorder(),
                        child: IconButton(
                          tooltip: 'Call rider',
                          onPressed: _call,
                          icon: const Icon(Icons.phone_rounded, color: Colors.white),
                        ),
                      ),
                  ]),
                ),
              if (step == 0 && !_o.cancelled) ...[
                PrimaryButton('Pay ${money(_o.amountTotal)} with M-Pesa',
                    icon: Icons.lock_outline_rounded,
                    onTap: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                        builder: (_) => PayScreen(order: _o, phone: AppStore.instance.phone.isNotEmpty ? AppStore.instance.phone : _o.phone)))),
              ],
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: Text('${_o.itemCount} items${_o.paid ? ' · paid with M-Pesa' : ''}',
                      style: const TextStyle(fontSize: 14, color: C.muted)),
                ),
                Text(money(_o.amountTotal), style: head(15, w: FontWeight.w600)),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}
