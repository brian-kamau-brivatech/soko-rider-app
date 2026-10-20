import 'package:flutter/material.dart';
import '../models/delivery_order.dart';
import '../services/odoo_service.dart';
import 'active_delivery_screen.dart';

class OrdersScreen extends StatefulWidget {
  final OdooService odooService;
  const OrdersScreen({super.key, required this.odooService});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<DeliveryOrder> _orders = [];
  bool _isLoading = true;

  static const Color sokoNavy = Color(0xFF0C2340);
  static const Color sokoGreen = Color(0xFF3CA227);

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    setState(() => _isLoading = true);
    final orders = await widget.odooService.getAssignedDeliveries();
    setState(() {
      _orders = orders;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('My Deliveries', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        backgroundColor: Colors.white,
        foregroundColor: sokoNavy,
        elevation: 0.5,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadOrders,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: sokoGreen))
          : _orders.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('🛵', style: TextStyle(fontSize: 54)),
                      const SizedBox(height: 12),
                      const Text('No Active Deliveries', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: sokoNavy)),
                      const SizedBox(height: 4),
                      const Text('New orders assigned to you will appear here.', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                      const SizedBox(height: 18),
                      ElevatedButton(
                        onPressed: _loadOrders,
                        style: ElevatedButton.styleFrom(backgroundColor: sokoNavy),
                        child: const Text('Check for New Orders', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadOrders,
                  color: sokoGreen,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _orders.length,
                    itemBuilder: (context, index) {
                      final order = _orders[index];
                      return Card(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        elevation: 1.5,
                        margin: const EdgeInsets.only(bottom: 16),
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEBF7E7),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      order.trackingNo,
                                      style: const TextStyle(color: sokoGreen, fontWeight: FontWeight.bold, fontSize: 12),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEFF6FF),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      'Payout: KSh ${order.riderPayout.toStringAsFixed(0)}',
                                      style: const TextStyle(color: Color(0xFF1D4ED8), fontWeight: FontWeight.bold, fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Text(order.customerName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: sokoNavy)),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(Icons.location_on, size: 16, color: Color(0xFF64748B)),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text('${order.deliveryArea} (${order.distanceKm.toStringAsFixed(1)} KM road distance)', style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.navigation, color: Colors.white),
                                  label: const Text('Start Delivery & Broadcast GPS', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: sokoNavy,
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                  ),
                                  onPressed: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ActiveDeliveryScreen(
                                          order: order,
                                          odooService: widget.odooService,
                                        ),
                                      ),
                                    ).then((_) => _loadOrders());
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
