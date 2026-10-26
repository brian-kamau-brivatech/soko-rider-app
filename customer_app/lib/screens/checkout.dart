import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'pay.dart';

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});
  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final _form = GlobalKey<FormState>();
  final _map = MapController();
  late final TextEditingController _name, _phone, _street, _street2;
  late LatLng _pin;
  bool _pinSet = false;
  Quote? _quote;
  bool _quoting = false;
  bool _locating = false;
  bool _placing = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final s = AppStore.instance;
    _name = TextEditingController(text: s.name);
    _phone = TextEditingController(text: s.phone);
    _street = TextEditingController(text: s.street);
    _street2 = TextEditingController(text: s.street2);
    if (s.lat != null && s.lng != null) {
      _pin = LatLng(s.lat!, s.lng!);
      _pinSet = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _requote());
    } else {
      final c = s.catalog;
      _pin = LatLng(c?.shopLat ?? -0.303099, c?.shopLng ?? 36.080026);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_name, _phone, _street, _street2]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onMove(MapCamera camera, bool hasGesture) {
    if (!hasGesture) return;
    _pin = camera.center;
    _pinSet = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _requote);
    setState(() {});
  }

  Future<void> _requote() async {
    setState(() => _quoting = true);
    try {
      final q = await ShopApi.quote(_pin.latitude, _pin.longitude, Map<int, double>.from(AppStore.instance.cart));
      if (mounted) setState(() => _quote = q);
    } catch (e) {
      if (mounted) setState(() => _quote = null);
    }
    if (mounted) setState(() => _quoting = false);
  }

  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) toast(context, 'Turn on location (GPS) and try again.');
        await Geolocator.openLocationSettings();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        if (mounted) toast(context, 'Allow location so we can find your gate. Or drag the map.');
        return;
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
      );
      _pin = LatLng(p.latitude, p.longitude);
      _pinSet = true;
      _map.move(_pin, 17);
      _requote();
    } catch (_) {
      if (mounted) toast(context, 'Could not get your location. Drag the map to your gate instead.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _place() async {
    if (!_form.currentState!.validate()) return;
    if (!_pinSet) {
      toast(context, 'Drag the map so the pin is on your gate, or tap "Use my location".');
      return;
    }
    if (_quote == null || !_quote!.ok) {
      toast(context, _quote?.error.isNotEmpty == true ? _quote!.error : 'Checking the delivery fee. Try again in a moment.');
      if (_quote == null) _requote();
      return;
    }
    final store = AppStore.instance;
    setState(() => _placing = true);
    try {
      await store.saveDetails(
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        street: _street.text.trim(),
        street2: _street2.text.trim(),
        lat: _pin.latitude,
        lng: _pin.longitude,
      );
      final order = await ShopApi.createOrder(
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        street: _street.text.trim(),
        street2: _street2.text.trim(),
        lat: _pin.latitude,
        lng: _pin.longitude,
        lines: Map<int, double>.from(store.cart),
        session: store.session,
      );
      await store.rememberOrder(order);
      store.clearCart();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => PayScreen(order: order, phone: _phone.text.trim())),
      );
    } catch (e) {
      if (mounted) toast(context, '$e');
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final sub = store.cartTotal;
    final fee = (_quote?.ok ?? false) ? _quote!.fee : null;
    return Scaffold(
      body: SafeArea(
        child: Form(
          key: _form,
          child: Column(children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                children: [
                  Row(children: [
                    const BackSquare(),
                    const SizedBox(width: 12),
                    Text('Delivery details', style: head(20)),
                  ]),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: SizedBox(
                      height: 220,
                      child: Stack(children: [
                        FlutterMap(
                          mapController: _map,
                          options: MapOptions(
                            initialCenter: _pin,
                            initialZoom: _pinSet ? 17 : 14,
                            onPositionChanged: _onMove,
                            interactionOptions: const InteractionOptions(
                              flags: InteractiveFlag.drag | InteractiveFlag.pinchZoom | InteractiveFlag.doubleTapZoom,
                            ),
                          ),
                          children: [
                            TileLayer(
                              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'ke.co.sokoexpressmtaani.soko_shop',
                            ),
                            const RichAttributionWidget(
                              alignment: AttributionAlignment.bottomLeft,
                              attributions: [TextSourceAttribution('OpenStreetMap contributors')],
                            ),
                          ],
                        ),
                        // Fixed pin in the middle: the customer moves the map under it.
                        IgnorePointer(
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 38),
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(color: C.ink, borderRadius: BorderRadius.circular(8)),
                                  child: const Text('Drop-off here', style: TextStyle(color: Colors.white, fontSize: 11.5)),
                                ),
                                const Icon(Icons.location_on, color: C.green, size: 40),
                              ]),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 10,
                          bottom: 10,
                          child: Material(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: _locating ? null : _useMyLocation,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  _locating
                                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: C.green))
                                      : const Icon(Icons.my_location_rounded, size: 17, color: C.green),
                                  const SizedBox(width: 6),
                                  const Text('Use my location', style: TextStyle(fontSize: 12.5, color: C.green)),
                                ]),
                              ),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _pinSet ? 'Drag the map to move the pin onto your gate.' : 'Drag the map so the pin is on your gate. Required.',
                    style: TextStyle(fontSize: 12.5, color: _pinSet ? C.muted : const Color(0xFFB45309)),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: cardBox(),
                    child: Column(children: [
                      _field(_name, 'Full name', Icons.person_outline_rounded, TextInputType.name,
                          (v) => v!.trim().length < 2 ? 'Enter your name' : null),
                      const SizedBox(height: 10),
                      _field(_phone, 'Phone number', Icons.phone_outlined, TextInputType.phone, (v) {
                        final d = v!.replaceAll(RegExp(r'[^0-9]'), '');
                        return d.length < 9 ? 'Enter your phone number, e.g. 0712 345 678' : null;
                      }),
                      const SizedBox(height: 10),
                      _field(_street, 'House, street, area', Icons.home_outlined, TextInputType.streetAddress,
                          (v) => v!.trim().length < 3 ? 'Enter your house / street / area' : null),
                      const SizedBox(height: 10),
                      _field(_street2, 'Gate, landmark (optional)', Icons.signpost_outlined, TextInputType.text, null),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: cardBox(),
                    child: Column(children: [
                      _row('Subtotal', money(sub)),
                      const SizedBox(height: 8),
                      _row(
                        (_quote?.ok ?? false) ? 'Delivery · ${_quote!.km.toStringAsFixed(1)} km' : 'Delivery · by distance',
                        _quoting ? 'Checking…' : (fee != null ? money(fee) : '—'),
                      ),
                      if (_quote != null && _quote!.ok) ...[
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${_kg(_quote!.weight)} kg · KES ${_kg(_quote!.rate)}/kg'
                            '${_quote!.basis == 'minimum' ? ' · minimum charge for this distance' : ''}',
                            style: const TextStyle(color: C.muted, fontSize: 12.5),
                          ),
                        ),
                      ],
                      if (_quote != null && !_quote!.ok && _quote!.error.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(_quote!.error, style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 13)),
                      ],
                      const Divider(height: 22, color: C.line),
                      Row(children: [
                        Expanded(child: Text('Total', style: head(16.5, w: FontWeight.w600))),
                        Text(fee != null ? money(sub + fee) : money(sub), style: head(16.5, w: FontWeight.w600)),
                      ]),
                    ]),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: PrimaryButton(
                fee != null ? 'Pay ${money(sub + fee)} with M-Pesa' : 'Pay with M-Pesa',
                icon: Icons.lock_outline_rounded,
                busy: _placing,
                onTap: _place,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, IconData icon, TextInputType type,
          String? Function(String?)? validator) =>
      TextFormField(
        controller: c,
        keyboardType: type,
        validator: validator,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, size: 20, color: C.muted),
          fillColor: C.bg,
        ),
      );

  Widget _row(String a, String b) => Row(children: [
        Expanded(child: Text(a, style: const TextStyle(color: C.muted, fontSize: 14.5))),
        Text(b, style: const TextStyle(fontSize: 14.5)),
      ]);
}

String _kg(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
