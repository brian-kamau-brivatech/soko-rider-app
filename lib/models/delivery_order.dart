/// A delivery order exactly as the Soko Odoo server sends it.
///
/// Nothing here is invented: if the server omits a value it stays null/empty
/// and the UI hides it or shows that it is missing.
class DeliveryOrder {
  final int id;
  final String trackingNo;
  final String saleOrder;
  final String customerName;
  final String customerPhone;
  final String deliveryArea;
  final String status;
  final double? destLat;
  final double? destLng;
  final double? distanceKm;
  final double? riderPayout;
  final double? amountTotal;
  final String itemsSummary; // e.g. "Fresh Vegetable Basket · 3 items" if the server sends it
  final DateTime? createdAt;
  final DateTime? pickedAt;
  final DateTime? deliveredAt;

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
    this.itemsSummary = '',
    this.createdAt,
    this.pickedAt,
    this.deliveredAt,
  });

  /// Website checkout requires a map location, so a valid order always has one.
  bool get hasLocation =>
      destLat != null && destLng != null && !(destLat == 0 && destLng == 0);

  static double? _num(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static String _str(dynamic v) => (v == null || v == false) ? '' : v.toString();

  /// Odoo sends datetimes as "2026-10-20 12:45:00" in UTC.
  static DateTime? _date(dynamic v) {
    if (v is! String || v.isEmpty) return null;
    final iso = v.contains('T') ? v : v.replaceFirst(' ', 'T');
    final parsed = DateTime.tryParse(iso.endsWith('Z') || iso.contains('+') ? iso : '${iso}Z');
    return parsed?.toLocal();
  }

  static String _items(Map<String, dynamic> json) {
    final s = _str(json['items_summary']);
    if (s.isNotEmpty) return s;
    final items = json['items'] ?? json['order_lines'];
    if (items is List && items.isNotEmpty) {
      final names = items
          .map((e) => e is Map ? _str(e['name'] ?? e['product']) : _str(e))
          .where((n) => n.isNotEmpty)
          .toList();
      if (names.isEmpty) return '';
      final first = names.first;
      return names.length == 1 ? first : '$first · ${names.length} items';
    }
    return '';
  }

  factory DeliveryOrder.fromOdooJson(Map<String, dynamic> json) {
    return DeliveryOrder(
      id: (json['id'] is int) ? json['id'] as int : 0,
      trackingNo: _str(json['tracking_no']),
      saleOrder: _str(json['sale_order']),
      customerName: _str(json['customer_name']),
      customerPhone: _str(json['customer_phone']),
      deliveryArea: _str(json['delivery_area']),
      status: _str(json['status']),
      destLat: _num(json['customer_lat']),
      destLng: _num(json['customer_lng']),
      distanceKm: _num(json['delivery_distance_km']),
      riderPayout: _num(json['rider_payout']),
      amountTotal: _num(json['amount_total']),
      itemsSummary: _items(json),
      createdAt: _date(json['create_date'] ?? json['created_at']),
      pickedAt: _date(json['picked_at'] ?? json['pickup_time']),
      deliveredAt: _date(json['delivered_at'] ?? json['delivery_time']),
    );
  }

  /// Human label for the Odoo status code, e.g. out_for_delivery -> Out For Delivery
  String get statusLabel {
    switch (_statusKey) {
      case 'out_for_delivery':
      case 'in_transit':
      case 'on_the_way':
        return 'In Transit';
      case 'delivered':
      case 'done':
        return 'Delivered';
    }
    if (status.isEmpty) return 'Unknown';
    return status
        .split(RegExp(r'[_\s]+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  String get _statusKey => status.trim().toLowerCase().replaceAll(' ', '_');

  bool get isDelivered => _statusKey == 'delivered' || _statusKey == 'done';

  /// Progress through Placed → Picked up → In transit → Delivered (0..3).
  int get progressStep {
    final s = _statusKey;
    if (isDelivered) return 3;
    if (s.contains('transit') || s.contains('out_for') || s.contains('on_the_way')) return 2;
    if (s.contains('pick') || s.contains('collected') || s.contains('dispatch')) return 1;
    return 0;
  }
}
