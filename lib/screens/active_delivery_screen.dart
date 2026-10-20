import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../config.dart';
import '../models/delivery_order.dart';
import '../services/location_stream_service.dart';
import '../services/odoo_service.dart';

class ActiveDeliveryScreen extends StatefulWidget {
  final DeliveryOrder order;
  final OdooService odooService;

  const ActiveDeliveryScreen({
    super.key,
    required this.order,
    required this.odooService,
  });

  @override
  State<ActiveDeliveryScreen> createState() => _ActiveDeliveryScreenState();
}

class _ActiveDeliveryScreenState extends State<ActiveDeliveryScreen> {
  final _locationService = LocationStreamService();
  final MapController _mapController = MapController();

  LatLng? _currentRiderPos;
  double _currentSpeed = 0.0;
  bool _isBroadcasting = false;
  bool _isCompleting = false;

  static const Color sokoNavy = Color(0xFF0C2340);
  static const Color sokoGreen = Color(0xFF3CA227);

  @override
  void initState() {
    super.initState();
    _startTracking();
  }

  Future<void> _startTracking() async {
    final started = await _locationService.startStreaming(
      wsUrl: AppConfig.wsStreamUrl,
      trackingToken: widget.order.trackingNo,
      onLocationUpdate: (Position pos) {
        if (!mounted) return;
        setState(() {
          _currentRiderPos = LatLng(pos.latitude, pos.longitude);
          _currentSpeed = (pos.speed * 3.6); // km/h
          _isBroadcasting = true;
        });
      },
    );

    if (!started && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not access GPS. Please check location permissions.')),
      );
    }
  }

  Future<void> _completeDelivery() async {
    setState(() => _isCompleting = true);
    final success = await widget.odooService.markOrderDelivered(widget.order.trackingNo);
    _locationService.stopStreaming();

    if (mounted) {
      if (success) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('🎉 Delivery Completed!'),
            content: Text('Order ${widget.order.trackingNo} has been marked as Delivered.\n\nPayout KSh ${widget.order.riderPayout.toStringAsFixed(0)} credited!'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context);
                },
                child: const Text('Back to Orders', style: TextStyle(fontWeight: FontWeight.bold, color: sokoGreen)),
              ),
            ],
          ),
        );
      } else {
        setState(() => _isCompleting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update status in Odoo.')),
        );
      }
    }
  }

  @override
  void dispose() {
    _locationService.stopStreaming();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final customerDest = LatLng(widget.order.destLat, widget.order.destLng);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.order.trackingNo, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        backgroundColor: Colors.white,
        foregroundColor: sokoNavy,
        elevation: 0.5,
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: customerDest,
              initialZoom: 14.5,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'ke.co.sokoexpressmtaani.rider',
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: customerDest,
                    width: 100,
                    height: 36,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: sokoNavy,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                      ),
                      child: Center(
                        child: Text(
                          widget.order.customerName,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                  if (_currentRiderPos != null)
                    Marker(
                      point: _currentRiderPos!,
                      width: 44,
                      height: 44,
                      child: Container(
                        decoration: BoxDecoration(
                          color: sokoGreen,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
                        ),
                        child: const Center(child: Text('🛵', style: TextStyle(fontSize: 20))),
                      ),
                    ),
                ],
              ),
            ],
          ),

          // Floating Live Status Card
          Positioned(
            bottom: 24,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 20, offset: const Offset(0, 4)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: _isBroadcasting ? sokoGreen : Colors.orange,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _isBroadcasting ? 'Broadcasting GPS Live' : 'Connecting GPS...',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _isBroadcasting ? sokoGreen : Colors.orange),
                          ),
                        ],
                      ),
                      Text(
                        '${_currentSpeed.toStringAsFixed(0)} km/h',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: sokoNavy),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('CUSTOMER', style: TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
                          Text(widget.order.customerName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: sokoNavy)),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text('YOUR PAYOUT', style: TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
                          Text('KSh ${widget.order.riderPayout.toStringAsFixed(0)}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: sokoGreen)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.check_circle, color: Colors.white),
                      label: _isCompleting
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text('Mark Order Delivered', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: sokoGreen,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: _isCompleting ? null : _completeDelivery,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
