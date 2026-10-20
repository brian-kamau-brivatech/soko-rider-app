import 'package:flutter/material.dart';
import '../models/delivery_order.dart';
import '../services/rider_data.dart';
import '../widgets/common.dart';
import '../widgets/order_card.dart';

class OrdersScreen extends StatelessWidget {
  final RiderData data;
  final Future<void> Function(DeliveryOrder) onOpen;
  const OrdersScreen({super.key, required this.data, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: data,
      builder: (context, _) {
        final active = data.activeOrders;
        final history = data.history;
        return SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: data.refresh,
            color: SokoColors.green,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 120),
              children: [
                const Text('My Orders', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: SokoColors.ink)),
                const SizedBox(height: 16),
                if (data.active != null && !data.active!.ok) ...[
                  ErrorPanel(message: data.active!.error ?? 'Could not load orders.', onRetry: data.refresh),
                  const SizedBox(height: 16),
                ],
                Text('Active (${data.active?.ok == true ? active.length : '—'})',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: SokoColors.ink)),
                const SizedBox(height: 12),
                if (data.active == null)
                  const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(color: SokoColors.green)))
                else if (data.active!.ok && active.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('No orders assigned to you right now.\nPull down to check again.',
                        textAlign: TextAlign.center, style: TextStyle(color: SokoColors.slate)),
                  ),
                for (final o in active)
                  Padding(padding: const EdgeInsets.only(bottom: 14), child: OrderCard(order: o, onTap: () => onOpen(o))),
                if (history != null && !history.notAvailable && history.ok && data.recentOrders.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Completed', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: SokoColors.ink)),
                  const SizedBox(height: 12),
                  for (final o in data.recentOrders) OrderTile(order: o),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
