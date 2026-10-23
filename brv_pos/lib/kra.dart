/// KRA eTIMS rules: code lists, tax maths and the exact VSCU payloads.
///
/// Built-in code lists are KRA's standard codes (same as the VSCU returns from
/// code/selectCodes). The app refreshes them from the VSCU in Settings.

class Code {
  final String code;
  final String name;
  final double rate; // tax types only
  const Code(this.code, this.name, [this.rate = 0]);
}

class Kra {
  // 04 Taxation type
  static const taxTypes = [
    Code('A', 'A-Exempt', 0),
    Code('B', 'B-Standard Rated 16%', 16),
    Code('C', 'C-Zero Rated', 0),
    Code('D', 'D-Non VAT', 0),
    Code('E', 'E-VAT 8%', 8),
  ];

  // 07 Payment type
  static const paymentTypes = [
    Code('01', 'Cash'),
    Code('02', 'Credit'),
    Code('03', 'Cash/Credit'),
    Code('04', 'Bank cheque'),
    Code('05', 'Debit & credit card'),
    Code('06', 'Mobile money'),
    Code('07', 'Other'),
  ];

  // 32 Refund (credit note) reason
  static const refundReasons = [
    Code('01', 'Missing quantity'),
    Code('02', 'Missing waiting'),
    Code('03', 'Damaged'),
    Code('04', 'Wasted'),
    Code('05', 'Raw material shortage'),
    Code('06', 'Refund'),
    Code('07', 'Wrong customer PIN'),
    Code('08', 'Wrong customer name'),
    Code('09', 'Wrong amount/price'),
    Code('10', 'Wrong quantity'),
    Code('11', 'Wrong item(s)'),
    Code('12', 'Wrong tax type'),
    Code('13', 'Other reason'),
  ];

  // 24 Item type
  static const itemTypes = [Code('1', 'Raw material'), Code('2', 'Finished product'), Code('3', 'Service')];

  // 10 Quantity unit (most used first)
  static const qtyUnits = [
    Code('U', 'Pieces/item'), Code('KG', 'Kilogram'), Code('GRM', 'Gram'), Code('LTR', 'Litre'), Code('L', 'Litre (L)'),
    Code('MTR', 'Metre'), Code('M2', 'Square metre'), Code('M3', 'Cubic metre'), Code('BX', 'Box'), Code('BG', 'Bag'),
    Code('PA', 'Packet'), Code('DZ', 'Dozen'), Code('SET', 'Set'), Code('PR', 'Pair'), Code('NO', 'Number'),
    Code('CA', 'Can'), Code('DR', 'Drum'), Code('RO', 'Roll'), Code('TU', 'Tube'), Code('ST', 'Sheet'),
    Code('MGM', 'Milligram'), Code('TNE', 'Tonne'), Code('GLL', 'Gallon'), Code('CMT', 'Centimetre'), Code('KTM', 'Kilometre'),
  ];

  // 17 Packaging unit (most used first)
  static const pkgUnits = [
    Code('NT', 'Net'), Code('OU', 'Non-exterior packaging'), Code('CT', 'Carton'), Code('BG', 'Bag'), Code('BX', 'Box (BX)'),
    Code('BQ', 'Bottle'), Code('CA', 'Can'), Code('JR', 'Jar'), Code('BE', 'Bundle'), Code('PU', 'Traypack'),
    Code('RO', 'Roll'), Code('DR', 'Drum'), Code('CY', 'Cylinder'), Code('BJ', 'Bucket'), Code('JY', 'Jerry can'),
    Code('TN', 'Tin'), Code('AM', 'Ampoule'), Code('BA', 'Barrel'), Code('BC', 'Bottle crate'), Code('GT', 'Extra countable item'),
  ];

  // Countries most used for origin (KRA uses ISO-2)
  static const origins = [
    Code('KE', 'Kenya'), Code('UG', 'Uganda'), Code('TZ', 'Tanzania'), Code('RW', 'Rwanda'), Code('ET', 'Ethiopia'),
    Code('ZA', 'South Africa'), Code('EG', 'Egypt'), Code('AE', 'United Arab Emirates'), Code('IN', 'India'), Code('CN', 'China'),
    Code('JP', 'Japan'), Code('GB', 'United Kingdom'), Code('DE', 'Germany'), Code('US', 'United States'), Code('NL', 'Netherlands'),
  ];

  static Code? find(List<Code> list, String code) {
    for (final c in list) {
      if (c.code == code) return c;
    }
    return null;
  }

  static double rate(String tax) => find(taxTypes, tax)?.rate ?? 0;
  static String paymentName(String code) => find(paymentTypes, code)?.name ?? code;
}

/// Round to 2 decimals, half up (KRA wants 2 decimals everywhere).
double r2(num v) {
  final x = v.toDouble();
  final s = x < 0 ? -1 : 1;
  return s * ((x.abs() * 100) + 1e-7).round() / 100;
}

/// yyyyMMddHHmmss / yyyyMMdd in local (Kenya) time.
String etimsDateTime(DateTime t) {
  String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
  return '${p(t.year, 4)}${p(t.month)}${p(t.day)}${p(t.hour)}${p(t.minute)}${p(t.second)}';
}

String etimsDate(DateTime t) => etimsDateTime(t).substring(0, 8);

DateTime? parseEtims(String? s) {
  if (s == null || s.length < 14) return null;
  try {
    return DateTime(int.parse(s.substring(0, 4)), int.parse(s.substring(4, 6)), int.parse(s.substring(6, 8)),
        int.parse(s.substring(8, 10)), int.parse(s.substring(10, 12)), int.parse(s.substring(12, 14)));
  } catch (_) {
    return null;
  }
}

/// "ABCDEFGH" -> "ABCD-EFGH" (KRA receipt format for internal data and signature).
String hyphenate(String? s, [int every = 4]) {
  final v = (s ?? '').replaceAll('-', '');
  final out = <String>[];
  for (var i = 0; i < v.length; i += every) {
    out.add(v.substring(i, i + every > v.length ? v.length : i + every));
  }
  return out.join('-');
}

/// Item code: origin + type + packaging + quantity unit, padded with a number to 20 chars,
/// e.g. KE2NTU00000000000039 (same scheme as Odoo).
String makeItemCode({required String origin, required String type, required String pkg, required String qty, required int seq}) {
  final prefix = '$origin$type$pkg$qty';
  final n = seq.toString();
  return prefix.padRight(20 - n.length, '0') + n;
}

/// One cart line, ready for KRA.
class SaleLineCalc {
  final int itemId;
  final String itemCd;
  final String itemClsCd;
  final String name;
  final String barcode;
  final String pkgUnit;
  final String qtyUnit;
  final String tax;
  final double qty; // 2 decimals
  final double priceIncl; // unit price including VAT, as on the shelf
  final double discountRate; // %

  // Results
  late final double gross; // qty x price, incl. VAT
  late final double discountIncl;
  late final double total; // what the customer pays for this line
  late final double taxable; // excl. VAT
  late final double taxAmt;

  SaleLineCalc({
    required this.itemId,
    required this.itemCd,
    required this.itemClsCd,
    required this.name,
    this.barcode = '',
    required this.pkgUnit,
    required this.qtyUnit,
    required this.tax,
    required double qty,
    required this.priceIncl,
    this.discountRate = 0,
  }) : qty = r2(qty) {
    final rate = Kra.rate(tax);
    gross = r2(this.qty * priceIncl);
    discountIncl = r2(gross * discountRate / 100);
    total = r2(gross - discountIncl);
    taxable = r2(total * 100 / (100 + rate));
    taxAmt = r2(total - taxable);
  }

  /// itemList entry. [taxableInclVat]: send prc/splyAmt VAT inclusive (taxblAmt is always without VAT)
  /// instead of excluding it (Odoo / VSCU default).
  Map<String, dynamic> toJson(int seq, {bool taxableInclVat = false}) {
    final rate = Kra.rate(tax);
    final Map<String, dynamic> m;
    if (taxableInclVat) {
      m = {
        'prc': r2(priceIncl), // unit price VAT inclusive
        'splyAmt': gross, // qty x price, VAT inclusive
        'dcRt': r2(discountRate),
        'dcAmt': discountIncl,
        'taxblAmt': taxable, // taxable amount = without VAT
        'taxAmt': taxAmt,
        'totAmt': total,
      };
    } else {
      final splyEx = r2(gross * 100 / (100 + rate));
      m = {
        'prc': qty == 0 ? 0.0 : r2(splyEx / qty),
        'splyAmt': splyEx,
        'dcRt': r2(discountRate),
        'dcAmt': r2(splyEx - taxable),
        'taxblAmt': taxable,
        'taxAmt': taxAmt,
        'totAmt': total,
      };
    }
    return {
      'itemSeq': seq,
      'itemCd': itemCd,
      'itemClsCd': itemClsCd,
      'itemNm': name.length > 200 ? name.substring(0, 200) : name,
      if (barcode.isNotEmpty) 'bcd': barcode,
      'pkgUnitCd': pkgUnit,
      'pkg': qty,
      'qtyUnitCd': qtyUnit,
      'qty': qty,
      ...m,
      'taxTyCd': tax,
      // Insurance fields: empty, exactly as the Odoo POS sends them to the VSCU.
      'isrccCd': '',
      'isrccNm': '',
      'isrcRt': '',
      'isrcAmt': '',
    };
  }
}

/// The whole trnsSales/saveSales request. Header totals are sums of the
/// rounded lines, so they always match KRA's checks.
Map<String, dynamic> buildSalePayload({
  required String tin,
  required String bhfId,
  required int invcNo,
  required String trdInvcNo,
  required List<SaleLineCalc> lines,
  required String paymentCode,
  required DateTime when,
  bool creditNote = false,
  int orgInvcNo = 0,
  String refundReason = '',
  String custTin = '',
  String custNm = '',
  String custMblNo = '',
  String userId = '1',
  String userName = 'BRV POS',
  bool taxableInclVat = false,
}) {
  final items = <Map<String, dynamic>>[];
  for (var i = 0; i < lines.length; i++) {
    items.add(lines[i].toJson(i + 1, taxableInclVat: taxableInclVat));
  }
  final byTax = <String, Map<String, double>>{};
  for (final t in ['A', 'B', 'C', 'D', 'E']) {
    byTax[t] = {'taxbl': 0, 'tax': 0};
  }
  for (final it in items) {
    final b = byTax[it['taxTyCd']]!;
    b['taxbl'] = r2(b['taxbl']! + (it['taxblAmt'] as double));
    b['tax'] = r2(b['tax']! + (it['taxAmt'] as double));
  }
  final totTaxbl = r2(items.fold<double>(0, (a, it) => a + (it['taxblAmt'] as double)));
  final totTax = r2(items.fold<double>(0, (a, it) => a + (it['taxAmt'] as double)));
  final totAmt = r2(items.fold<double>(0, (a, it) => a + (it['totAmt'] as double)));
  final cfm = etimsDateTime(when);
  String cut(String s, int n) => s.length > n ? s.substring(0, n) : s;
  // Same fields as the Odoo POS sends successfully to your VSCU.
  return {
    'tin': tin,
    'bhfId': bhfId,
    'invcNo': invcNo,
    'trdInvcNo': cut(trdInvcNo, 50),
    'orgInvcNo': creditNote ? orgInvcNo : 0,
    'cfmDt': cfm,
    'pmtTyCd': paymentCode,
    'rcptTyCd': creditNote ? 'R' : 'S',
    'salesTyCd': 'N',
    'custTin': cut(custTin, 11),
    'custNm': cut(custNm, 60),
    'custMblNo': cut(custMblNo, 20),
    'salesSttsCd': '02',
    'salesDt': etimsDate(when),
    if (creditNote) 'rfdRsnCd': refundReason,
    'totItemCnt': items.length,
    for (final t in ['A', 'B', 'C', 'D', 'E']) 'taxblAmt$t': byTax[t]!['taxbl'],
    for (final t in ['A', 'B', 'C', 'D', 'E']) 'taxRt$t': Kra.rate(t),
    for (final t in ['A', 'B', 'C', 'D', 'E']) 'taxAmt$t': byTax[t]!['tax'],
    'totTaxblAmt': totTaxbl,
    'totTaxAmt': totTax,
    'totAmt': totAmt,
    'prchrAcptcYn': 'Y',
    'regrId': userId,
    'regrNm': userName,
    'modrId': userId,
    'modrNm': userName,
    'receipt': {
      'custTin': cut(custTin, 11),
      'rcptPbctDt': cfm,
      'prchrAcptcYn': 'N',
      'custMblNo': cut(custMblNo, 20),
      'adrs': '',
    },
    'itemList': items,
  };
}

/// KRA receipt check link (QR code content).
String receiptUrl({required bool test, required String tin, required String bhfId, required String rcptSign}) {
  final host = test ? 'etims-sbx.kra.go.ke' : 'etims.kra.go.ke';
  return 'https://$host/common/link/etims/receipt/indexEtimsReceiptData?Data=$tin$bhfId${rcptSign.replaceAll('-', '')}';
}

/// "expected invoice number is: 123" style messages from the VSCU.
int? expectedInvoiceNo(String msg) {
  final m = RegExp(r'expected[^0-9]*(\d+)', caseSensitive: false).firstMatch(msg);
  return m == null ? null : int.tryParse(m.group(1)!);
}
