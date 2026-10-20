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

  @override
  void initState() {
    super.initState();
    _startTracking();
  }

  Future<void> _startTracking() async {
    final started = await _locationService.startStreaming(
      wsUrl: AppConfig.defaultWsBridgeUrl,
      trackingToken: widget.order.trackingToken,
      onLocationUpdate: (Position pos) {
        if (!mounted) return;
        setState(() {
          _currentRiderPos = LatLng(pos.latitude, pos.longitude);
          _currentSpeed = (pos.speed * 3.6); // convert m/s to km/h
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
    final success = await widget.odooService.markOrderDelivered(widget.order.id);
    _locationService.stopStreaming();

    if (mounted) {
      if (success) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('🎉 Delivery Completed!'),
            content: const Text('Order has been validated in Odoo ERP and customer notified.'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context);
                },
                child: const Text('Back to Orders'),
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
        title: Text(widget.order.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        elevation: 0.5,
      ),
      body: Column(
        children: [
          // GPS Broadcasting Status Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFF0F172A),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _isBroadcasting ? const Color(0xFF22C55E) : const Color(0xFFEAB308),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isBroadcasting ? 'GPS STREAMING LIVE' : 'CONNECTING GPS...',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ],
                ),
                Text(
                  '${_currentSpeed.toStringAsFixed(1)} km/h',
                  style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),

          // 100% Free OpenStreetMap via flutter_map
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _currentRiderPos ?? customerDest,
                initialZoom: 15.0,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.odoo.rider_app',
                ),
                MarkerLayer(
                  markers: [
                    // Customer Drop-off Pin
                    Marker(
                      point: customerDest,
                      width: 40,
                      height: 40,
                      child: const Icon(Icons.location_on, color: Colors.red, size: 40),
                    ),
                    // Rider Realtime Pin
                    if (_currentRiderPos != null)
                      Marker(
                        point: _currentRiderPos!,
                        width: 44,
                        height: 44,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF2563EB),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 8),
                            ],
                          ),
                          child: const Icon(Icons.navigation, color: Colors.white, size: 22),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),

          // Bottom Action Panel
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              boxShadow: [
                BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, -3)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.order.customerName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text(widget.order.deliveryAddress, style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.phone, color: Color(0xFF2563EB)),
                      onPressed: () {
                        // Launch phone dialer
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _isCompleting ? null : _completeDelivery,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isCompleting
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Mark as Delivered (Sync to Odoo)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
