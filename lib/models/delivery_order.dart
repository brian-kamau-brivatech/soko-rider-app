class DeliveryOrder {
  final int id;
  final String name;
  final String customerName;
  final String customerPhone;
  final String deliveryAddress;
  final String trackingToken;
  final double destLat;
  final double destLng;
  final String state;

  DeliveryOrder({
    required this.id,
    required this.name,
    required this.customerName,
    required this.customerPhone,
    required this.deliveryAddress,
    required this.trackingToken,
    required this.destLat,
    required this.destLng,
    required this.state,
  });

  factory DeliveryOrder.fromOdooJson(Map<String, dynamic> json) {
    final partner = json['partner_id'];
    String custName = 'Customer';
    if (partner is List && partner.length > 1) {
      custName = partner[1].toString();
    }

    return DeliveryOrder(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      customerName: custName,
      customerPhone: json['partner_phone'] ?? '',
      deliveryAddress: json['delivery_address'] ?? 'Customer Address',
      trackingToken: json['tracking_token'] ?? '',
      destLat: (json['delivery_latitude'] is num) ? (json['delivery_latitude'] as num).toDouble() : -1.286389,
      destLng: (json['delivery_longitude'] is num) ? (json['delivery_longitude'] as num).toDouble() : 36.817223,
      state: json['state'] ?? 'assigned',
    );
  }
}
