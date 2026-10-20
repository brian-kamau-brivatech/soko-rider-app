import 'package:flutter/material.dart';
import '../config.dart';
import '../models/delivery_order.dart';
import 'common.dart';

/// Big "Current Delivery" card: item, status, progress, pickup → drop-off.
class OrderCard extends StatelessWidget {
  final DeliveryOrder order;
  final VoidCallback onTap;
  const OrderCard({super.key, required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final title = order.trackingNo.isEmpty ? 'No tracking no.' : order.trackingNo;
    final subtitle = [
      if (order.itemsSummary.isNotEmpty) order.itemsSummary else if (order.saleOrder.isNotEmpty) order.saleOrder,
      if (order.customerName.isNotEmpty) order.customerName,
    ].join(' · ');

    return SokoCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _emojiTile(orderEmoji(order.itemsSummary)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: SokoColors.ink)),
                    if (subtitle.isNotEmpty)
                      Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: SokoColors.slate)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusPill(order.statusLabel),
            ],
          ),
          SizedBox(height: order.distanceKm != null ? 34 : 18),
          ProgressSteps(
            step: order.progressStep,
            currentBadge: order.distanceKm != null ? '${order.distanceKm!.toStringAsFixed(1)} km trip' : null,
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(order.pickedAt != null ? 'Picked: ${formatDateTime(order.pickedAt!)}' : 'Pick-up',
                        style: const TextStyle(fontSize: 12, color: SokoColors.slate)),
                    const Text(AppConfig.shopName, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SokoColors.ink)),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Drop-off', style: TextStyle(fontSize: 12, color: SokoColors.slate)),
                    Text(order.deliveryArea.isEmpty ? (order.hasLocation ? 'Pinned location' : 'No location!') : order.deliveryArea,
                        textAlign: TextAlign.end,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: order.hasLocation ? SokoColors.ink : SokoColors.red)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.payments_outlined, size: 18, color: SokoColors.green),
              const SizedBox(width: 6),
              Text('Payout ${formatKsh(order.riderPayout)}',
                  style: const TextStyle(fontWeight: FontWeight.w700, color: SokoColors.ink, fontSize: 13)),
              const Spacer(),
              const Text('Open tracking', style: TextStyle(color: SokoColors.green, fontWeight: FontWeight.w700, fontSize: 13)),
              const Icon(Icons.chevron_right, color: SokoColors.green),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact row used in "Recent Dispatches" and the Orders list.
class OrderTile extends StatelessWidget {
  final DeliveryOrder order;
  final VoidCallback? onTap;
  const OrderTile({super.key, required this.order, this.onTap});

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (order.itemsSummary.isNotEmpty) order.itemsSummary else if (order.customerName.isNotEmpty) order.customerName,
      if (order.deliveryArea.isNotEmpty) order.deliveryArea,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SokoCard(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            _emojiTile(orderEmoji(order.itemsSummary), size: 48),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(order.trackingNo.isEmpty ? 'No tracking no.' : order.trackingNo,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: SokoColors.ink)),
                  if (subtitle.isNotEmpty)
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: SokoColors.slate)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            StatusPill(order.statusLabel),
          ],
        ),
      ),
    );
  }
}

Widget _emojiTile(String emoji, {double size = 58}) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: SokoColors.background, borderRadius: BorderRadius.circular(16)),
      child: Center(child: Text(emoji, style: TextStyle(fontSize: size * 0.48))),
    );
