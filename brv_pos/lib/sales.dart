import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'db.dart';
import 'kra.dart';
import 'settings.dart';
import 'vscu.dart';

/// Bumped whenever a sale is added or changes, so lists refresh.
final salesVersion = ValueNotifier<int>(0);

/// A sale (or credit note) as stored on this device.
class Sale {
  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> lines;
  Sale(this.row, this.lines);

  int get id => row['id'] as int;
  int get invcNo => row['invc_no'] as int;
  String get number => row['trd_invc_no'] as String;
  bool get isCredit => row['kind'] == 'R';
  String get status => row['status'] as String;
  bool get signed => status == 'signed';
  bool get pending => status == 'pending';
  DateTime get created => DateTime.tryParse(row['created_at'] as String? ?? '') ?? DateTime.now();
  double get total => (row['tot_amt'] as num?)?.toDouble() ?? 0;
  double get tax => (row['tot_tax'] as num?)?.toDouble() ?? 0;
  double get tendered => (row['tendered'] as num?)?.toDouble() ?? 0;
  String get paymentCode => row['pmt_ty_cd'] as String? ?? '';
  String get customerTin => row['cust_tin'] as String? ?? '';
  String get customerName => row['cust_nm'] as String? ?? '';
  String get error => row['error'] as String? ?? '';
  int get copies => row['copies'] as int? ?? 0;
  Map<String, dynamic> get payload {
    try {
      return Map<String, dynamic>.from(jsonDecode(row['payload'] as String? ?? '{}'));
    } catch (_) {
      return {};
    }
  }

  static Future<Sale?> load(int id) async {
    final db = await Db.get();
    final r = await db.query('sales', where: 'id = ?', whereArgs: [id], limit: 1);
    if (r.isEmpty) return null;
    final lines = await db.query('sale_lines', where: 'sale_id = ?', whereArgs: [id], orderBy: 'id');
    return Sale(Map<String, dynamic>.from(r.first), lines.map((e) => Map<String, dynamic>.from(e)).toList());
  }
}

class SaleOutcome {
  final Sale? sale;
  final String? error;
  final int? expectedNo; // VSCU says another invoice number is expected
  SaleOutcome({this.sale, this.error, this.expectedNo});
  bool get ok => sale != null && sale!.signed;
}

class Sales {
  /// A sale whose VSCU answer never arrived: it must be re-sent before anything else.
  static Future<Sale?> pendingSale() async {
    final db = await Db.get();
    final r = await db.query('sales', columns: ['id'], where: "status = 'pending'", orderBy: 'id', limit: 1);
    return r.isEmpty ? null : Sale.load(r.first['id'] as int);
  }

  /// Make sure every item on the sale is registered with KRA first.
  static Future<String?> _registerItems(List<SaleLineCalc> lines) async {
    final db = await Db.get();
    for (final id in lines.map((l) => l.itemId).toSet()) {
      final r = await db.query('items', where: 'id = ?', whereArgs: [id], limit: 1);
      if (r.isEmpty) continue;
      final item = Map<String, dynamic>.from(r.first);
      if (item['registered'] == 1) continue;
      final res = await Vscu.saveItem(item);
      if (!res.ok) return '"${item['name']}" is not registered with KRA: ${res.message}';
    }
    return null;
  }

  /// Sign a sale (or credit note) with the VSCU and save it.
  static Future<SaleOutcome> sell({
    required List<SaleLineCalc> lines,
    required String paymentCode,
    double tendered = 0,
    String custTin = '',
    String custNm = '',
    String custMbl = '',
    bool creditNote = false,
    int orgInvcNo = 0,
    String refundReason = '',
  }) async {
    final s = Settings.i;
    if (!s.ready) return SaleOutcome(error: 'Set up and initialise the device in Settings first.');
    if (lines.isEmpty) return SaleOutcome(error: 'Add at least one item.');
    if (lines.any((l) => l.qty <= 0)) return SaleOutcome(error: 'Quantities must be more than zero.');
    final waiting = await pendingSale();
    if (waiting != null) {
      return SaleOutcome(error: 'Sale ${waiting.number} is still waiting for the VSCU. Open Sales and tap Retry first.');
    }
    final regError = await _registerItems(lines);
    if (regError != null) return SaleOutcome(error: regError);

    final db = await Db.get();
    final now = DateTime.now();
    late int saleId;
    late Map<String, dynamic> payload;
    await db.transaction((tx) async {
      final invcNo = await Db.nextInvoiceNo(tx: tx);
      final number = '${creditNote ? 'CN' : 'INV'}-${s.bhfId}-${invcNo.toString().padLeft(6, '0')}';
      payload = buildSalePayload(
        tin: s.tin,
        bhfId: s.bhfId,
        invcNo: invcNo,
        trdInvcNo: number,
        lines: lines,
        paymentCode: paymentCode,
        when: now,
        creditNote: creditNote,
        orgInvcNo: orgInvcNo,
        refundReason: refundReason,
        custTin: custTin.trim().toUpperCase(),
        custNm: custNm.trim(),
        custMblNo: custMbl.trim(),
        userName: s.cashier.isEmpty ? 'BRV POS' : s.cashier,
        taxableInclVat: s.taxableInclVat,
      );
      saleId = await tx.insert('sales', {
        'invc_no': invcNo,
        'trd_invc_no': number,
        'kind': creditNote ? 'R' : 'S',
        'org_invc_no': orgInvcNo,
        'rfd_rsn': refundReason,
        'status': 'pending',
        'created_at': now.toIso8601String(),
        'day': now.toIso8601String().substring(0, 10),
        'cust_tin': payload['custTin'],
        'cust_nm': payload['custNm'],
        'cust_mbl': payload['custMblNo'],
        'pmt_ty_cd': paymentCode,
        'tendered': tendered,
        'tot_taxbl': payload['totTaxblAmt'],
        'tot_tax': payload['totTaxAmt'],
        'tot_amt': payload['totAmt'],
        'item_cnt': lines.length,
        'cashier': s.cashier,
        'payload': jsonEncode(payload),
      });
      for (final l in lines) {
        await tx.insert('sale_lines', {
          'sale_id': saleId,
          'item_id': l.itemId,
          'item_cd': l.itemCd,
          'name': l.name,
          'tax': l.tax,
          'qty': l.qty,
          'price': l.priceIncl,
          'dc_rt': l.discountRate,
          'dc_amt': l.discountIncl,
          'taxbl': l.taxable,
          'tax_amt': l.taxAmt,
          'tot': l.total,
        });
      }
    });
    return _send(saleId, payload);
  }

  /// Re-send a pending sale with the same invoice number and data.
  static Future<SaleOutcome> retry(Sale sale) => _send(sale.id, sale.payload);

  /// Give up on a sale the VSCU refused (its number was not used).
  static Future<void> discard(Sale sale) async {
    final db = await Db.get();
    await db.update('sales', {'status': 'failed'}, where: 'id = ?', whereArgs: [sale.id]);
    salesVersion.value++;
  }

  /// Count a reprint (COPY receipt).
  static Future<void> countCopy(Sale sale) async {
    final db = await Db.get();
    await db.rawUpdate('UPDATE sales SET copies = copies + 1 WHERE id = ?', [sale.id]);
    salesVersion.value++;
  }

  static Future<SaleOutcome> _send(int saleId, Map<String, dynamic> payload) async {
    try {
      return await _sendOnce(saleId, payload);
    } finally {
      salesVersion.value++;
    }
  }

  static Future<SaleOutcome> _sendOnce(int saleId, Map<String, dynamic> payload) async {
    final db = await Db.get();
    final res = await Vscu.call('trnsSales/saveSales', payload);
    final invcNo = payload['invcNo'] as int;

    if (res.ok) {
      final d = res.data;
      String v(String k) => d[k] == null ? '' : '${d[k]}';
      final pub = v('vsdcRcptPbctDate').isNotEmpty
          ? v('vsdcRcptPbctDate')
          : (v('VSCURcptPbctDate').isNotEmpty ? v('VSCURcptPbctDate') : (v('sdcDateTime').isNotEmpty ? v('sdcDateTime') : etimsDateTime(DateTime.now())));
      await db.transaction((tx) async {
        await tx.update('sales', {
          'status': 'signed',
          'error': '',
          'response': jsonEncode(res.raw),
          'rcpt_no': int.tryParse(v('rcptNo')) ?? int.tryParse(v('curRcptNo')),
          'tot_rcpt_no': int.tryParse(v('totRcptNo')),
          'intrl_data': v('intrlData'),
          'rcpt_sign': v('rcptSign'),
          'sdc_id': v('sdcId').isNotEmpty ? v('sdcId') : Settings.i.controlUnitId,
          'mrc_no': v('mrcNo').isNotEmpty ? v('mrcNo') : Settings.i.mrcNo,
          'sdc_date': pub,
        }, where: 'id = ?', whereArgs: [saleId]);
        // The number is used: move the counter on (never backwards).
        if (await Db.nextInvoiceNo(tx: tx) <= invcNo) await Db.setNextInvoiceNo(invcNo + 1, tx: tx);
      });
      final s = Settings.i;
      if ((s.controlUnitId.isEmpty && v('sdcId').isNotEmpty) || (s.mrcNo.isEmpty && v('mrcNo').isNotEmpty)) {
        if (v('sdcId').isNotEmpty) s.controlUnitId = v('sdcId');
        if (v('mrcNo').isNotEmpty) s.mrcNo = v('mrcNo');
        await s.save();
      }
      return SaleOutcome(sale: await Sale.load(saleId));
    }

    if (res.noAnswer) {
      // Unknown outcome: keep the number reserved and re-send the same sale later.
      await db.update('sales', {'error': res.message}, where: 'id = ?', whereArgs: [saleId]);
      return SaleOutcome(
        sale: await Sale.load(saleId),
        error: '${res.message}\nThe sale is saved as waiting. Tap Retry when the connection is back. '
            'It keeps the same invoice number, so it is never signed twice.',
      );
    }

    // "Already exists" style refusals: the number is taken at KRA, so never reuse it.
    final duplicate = const {'12', '902', '994'}.contains(res.code) ||
        RegExp(r'already|duplicate|exist', caseSensitive: false).hasMatch(res.msg);
    if (duplicate) {
      await db.transaction((tx) async {
        await tx.update('sales', {'status': 'failed', 'error': 'Invoice number $invcNo is already used at KRA. ${res.message}'},
            where: 'id = ?', whereArgs: [saleId]);
        if (await Db.nextInvoiceNo(tx: tx) <= invcNo) await Db.setNextInvoiceNo(invcNo + 1, tx: tx);
      });
      return SaleOutcome(
          sale: await Sale.load(saleId),
          error: 'Invoice number $invcNo was already used at KRA, so the app moved on to ${invcNo + 1}. '
              'Charge again to sign this sale with the next number.');
    }

    // The VSCU answered with a refusal: the number was not used.
    await db.update('sales', {'status': 'failed', 'error': res.message}, where: 'id = ?', whereArgs: [saleId]);
    return SaleOutcome(sale: await Sale.load(saleId), error: 'KRA refused the sale: ${res.message}',
        expectedNo: expectedInvoiceNo(res.msg));
  }
}
