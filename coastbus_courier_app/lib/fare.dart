import 'master.dart';
import 'fmt.dart';

/// Same rule as Odoo (models/common.py charge()).
class Fare {
  final double volWeight, chargeable, fare, insurance, total, vat;
  const Fare(this.volWeight, this.chargeable, this.fare, this.insurance, this.total, this.vat);

  static Fare? compute({required int origin, required int dest, required double weight, double l = 0, double w = 0, double h = 0,
      double declared = 0, bool insured = false, int pieces = 1}) {
    final r = Master.i.route(origin, dest);
    if (r == null) return null;
    final m = Master.i;
    final divisor = m.num_('vol_divisor', 5000);
    final vol = divisor > 0 ? l * w * h / divisor : 0.0;
    final chargeable = weight > vol ? weight : vol;
    final baseKg = d(r['base_kg']);
    final extra = chargeable > baseKg ? (double.parse((chargeable - baseKg).toStringAsFixed(3))).ceil() : 0;
    var fare = d(r['base_fare']) + extra * d(r['rate_per_kg']) + (pieces > 1 ? (pieces - 1) * d(r['extra_piece_fee']) : 0);
    if (fare < d(r['min_charge'])) fare = d(r['min_charge']);
    var ins = 0.0;
    if (insured && declared > 0) {
      ins = (declared * m.num_('insurance_pct') / 100).roundToDouble();
      final mn = m.num_('insurance_min');
      if (ins < mn) ins = mn;
    }
    final total = double.parse((fare + ins).toStringAsFixed(2));
    final vp = m.num_('vat_pct');
    final vat = vp > 0 ? double.parse((total * vp / (100 + vp)).toStringAsFixed(2)) : 0.0;
    return Fare(double.parse(vol.toStringAsFixed(2)), double.parse(chargeable.toStringAsFixed(2)), double.parse(fare.toStringAsFixed(2)), ins, total, vat);
  }
}
