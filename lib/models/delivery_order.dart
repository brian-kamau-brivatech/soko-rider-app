class DeliveryOrder {
  final int id;
  final String trackingNo;
  final String saleOrder;
  final String customerName;
  final String customerPhone;
  final String deliveryArea;
  final String status;
  final double destLat;
  final double destLng;
  final double distanceKm;
  final double riderPayout;
  final double amountTotal;

  DeliveryOrder({
    required this.id,
    required this.trackingNo,
    required this.saleOrder,
    required this.customerName,
    required this.customerPhone,
    required this.deliveryArea,
    required this.status,
    required this.destLat,
    required this.destLng,
    required this.distanceKm,
    required this.riderPayout,
    required this.amountTotal,
  });

  factory DeliveryOrder.fromOdooJson(Map<String, dynamic> json) {
    return DeliveryOrder(
      id: json['id'] ?? 0,
      trackingNo: json['tracking_no'] ?? '',
      saleOrder: json['sale_order'] ?? '',
      customerName: json['customer_name'] ?? 'Customer',
      customerPhone: json['customer_phone'] ?? '',
      deliveryArea: json['delivery_area'] ?? 'Nakuru',
      status: json['status'] ?? 'preparing',
      destLat: (json['customer_lat'] is num) ? (json['customer_lat'] as num).toDouble() : -0.298000,
      destLng: (json['customer_lng'] is num) ? (json['customer_lng'] as num).toDouble() : 36.095000,
      distanceKm: (json['delivery_distance_km'] is num) ? (json['delivery_distance_km'] as num).toDouble() : 4.2,
      riderPayout: (json['rider_payout'] is num) ? (json['rider_payout'] as num).toDouble() : 120.0,
      amountTotal: (json['amount_total'] is num) ? (json['amount_total'] as num).toDouble() : 0.0,
    );
  }
}
