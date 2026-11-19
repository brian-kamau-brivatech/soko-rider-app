import 'fmt.dart';
import 'settings.dart';

/// The VAT groups (KRA eTIMS tax types A to E) and their general legal references.
class TaxGroup {
  final String code;
  final String name;
  final double rate;
  final String general; // printed when the VAT reference setting is "General"
  const TaxGroup(this.code, this.name, this.rate, this.general);
  String get label => '$code - $name';
}

const taxGroups = <TaxGroup>[
  TaxGroup('A', 'Exempt', 0, 'VAT Act 2013, s.2 and First Schedule (exempt supplies)'),
  TaxGroup('B', 'Standard rate 16%', 16, 'VAT Act 2013, s.5(2)(a) (standard rate)'),
  TaxGroup('C', 'Zero-rated', 0, 'VAT Act 2013, s.7 and Second Schedule (zero-rated supplies)'),
  TaxGroup('D', 'Non-VAT', 0, 'Not subject to VAT (outside the scope of the VAT Act 2013)'),
  TaxGroup('E', 'Reduced rate 8%', 8, 'VAT Act 2013, s.5(2)(b) (8% rate)'),
];

TaxGroup taxGroup(String code) => taxGroups.firstWhere((g) => g.code == code, orElse: () => taxGroups[1]);

/// Tax group of a product row. Old products (made before tax groups) only have a rate: 16 -> B, 8 -> E, 0 -> A.
String taxCdOf(Map<String, Object?> p) {
  final c = s(p['tax_cd']).toUpperCase();
  if (taxGroups.any((g) => g.code == c)) return c;
  final r = d(p['tax_rate']);
  return r >= 15 ? 'B' : (r >= 7 ? 'E' : 'A');
}

double taxRateOf(Map<String, Object?> p) => taxGroup(taxCdOf(p)).rate;

/// VAT references: "general" prints the group's general reference; "specify" lets each item carry
/// the exact Schedule paragraph chosen from the list loaded on the device.
bool get vatRefSpecify => Settings.i.get('vat_ref_mode') == 'specify';

String generalRef(String code) {
  final own = Settings.i.get('vat_gen_$code');
  return own.isNotEmpty ? own : taxGroup(code).general;
}
