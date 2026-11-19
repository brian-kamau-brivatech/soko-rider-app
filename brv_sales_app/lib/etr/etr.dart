import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import '../config.dart';
import '../db.dart';
import '../fmt.dart';
import '../sales.dart';
import '../session.dart';
import '../settings.dart';
import '../tax.dart';
import 'kra.dart';

class VscuResult {
  final bool ok;
  final String code; // KRA resultCd ("000" = success); empty when no answer
  final String msg;
  final Map<String, dynamic> data;
  final Map<String, dynamic>? raw;
  final bool noAnswer; // network problem: outcome unknown
  VscuResult({required this.ok, this.code = '', this.msg = '', this.data = const {}, this.raw, this.noAnswer = false});

  String get message => ok ? (msg.isEmpty ? 'Successful' : msg) : (code.isEmpty ? msg : '$code: $msg');

  /// "Already exists" style refusal: the invoice number is taken at KRA, never reuse it.
  bool get duplicate =>
      !ok && !noAnswer && (const {'12', '902', '994'}.contains(code) || RegExp(r'already|duplicate|exist', caseSensitive: false).hasMatch(msg));
}

/// KRA eTIMS for BRV Handheld ETR: the VSCU set-up of this handheld, item registration, and signing.
///
/// Rule: a sale is signed by KRA first and saved here only when KRA signed it (or did not answer, in
/// which case it is saved as "waiting" with its invoice number and re-sent with the same number).
/// A refused sale is not saved at all: the cart stays as it was.
class Etr {
  static Settings get _s => Settings.i;

  // ---- this handheld's VSCU set-up (kept on this device only, never synced or restored from a backup) ----
  static String get url => _s.get('etr_url');
  static String get root => url.trim().replaceAll(RegExp(r'/+$'), '');
  static String get tin => _s.get('etr_tin');
  static String get bhfId => _s.get('etr_bhf', '00');
  static String get serial => _s.get('etr_serial');
  static bool get initialised => _s.flag('etr_init');
  static bool get inclVat => _s.flag('etr_incl', true);
  static String get defaultClass => _s.get('etr_cls');
  static String get taxpayer => _s.get('etr_taxpayer');
  static String get branch => _s.get('etr_branch');
  static String get sdcId => _s.get('etr_sdc');
  static String get mrcNo => _s.get('etr_mrc');
  static bool get ready => isEtrApp && initialised && root.isNotEmpty && tin.isNotEmpty;

  static Future<int> nextInvoice() async => int.tryParse(await Db.kv('etr_next_invc') ?? '') ?? 1;
  static Future<void> setNextInvoice(int v) => Db.setKv('etr_next_invc', '$v');
  static Future<void> _moveOn(int used) async {
    if (await nextInvoice() <= used) await setNextInvoice(used + 1); // never backwards
  }

  // ---- technician PIN (locks the VSCU set-up) ----
  static String _hash(String pin) => sha256.convert(utf8.encode('brv-etr:${pin.trim()}')).toString();
  static bool get hasTechPin => _s.get('etr_tech').isNotEmpty;
  static bool techOk(String pin) => hasTechPin && _s.get('etr_tech') == _hash(pin);
  static Future<void> setTechPin(String pin) => _s.set('etr_tech', _hash(pin));

  // ---------------------------------------------------------------------------
  // VSCU calls
  // ---------------------------------------------------------------------------
  static Future<VscuResult> call(String path, Map<String, dynamic> body, {Duration? timeout}) async {
    final started = DateTime.now();
    final payload = {'tin': tin, 'bhfId': bhfId, ...body};
    VscuResult res;
    try {
      final r = await http
          .post(Uri.parse('$root/$path'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload))
          .timeout(timeout ?? (path.startsWith('trnsSales') ? const Duration(seconds: 100) : const Duration(seconds: 30)));
      dynamic j;
      try {
        j = jsonDecode(r.body);
      } catch (_) {}
      if (j is! Map) {
        res = VscuResult(ok: false, msg: 'The VSCU did not answer with data (HTTP ${r.statusCode}).');
      } else {
        final m = Map<String, dynamic>.from(j);
        final code = '${m['resultCd'] ?? ''}';
        final data = m['data'] is Map ? Map<String, dynamic>.from(m['data'] as Map) : <String, dynamic>{};
        res = VscuResult(ok: code == '000', code: code, msg: '${m['resultMsg'] ?? ''}', data: data, raw: m);
      }
    } on TimeoutException {
      res = VscuResult(ok: false, noAnswer: true, msg: 'No answer from the VSCU in time.');
    } catch (_) {
      res = VscuResult(ok: false, noAnswer: true, msg: 'Cannot reach the VSCU. Check the internet and the VSCU address.');
    }
    try {
      final db = await Db.get();
      await db.insert('etr_calls', {
        'at': nowIso(), 'path': path, 'ok': res.ok ? 1 : 0, 'code': res.code, 'msg': res.msg,
        'ms': DateTime.now().difference(started).inMilliseconds, 'request': jsonEncode(payload),
        'response': jsonEncode(res.raw ?? {'error': res.msg}),
      });
      await db.execute('DELETE FROM etr_calls WHERE id <= (SELECT MAX(id) - 500 FROM etr_calls)');
    } catch (_) {}
    return res;
  }

  /// Is the VSCU address reachable at all?
  static Future<(bool, String)> ping(String address) async {
    final r0 = address.trim().replaceAll(RegExp(r'/+$'), '');
    final started = DateTime.now();
    try {
      final r = await http.get(Uri.parse(r0)).timeout(const Duration(seconds: 8));
      return (true, 'Reachable (HTTP ${r.statusCode}, ${DateTime.now().difference(started).inMilliseconds} ms)');
    } on TimeoutException {
      return (false, 'No answer within 8 seconds.');
    } catch (_) {
      return (false, 'Cannot connect. Check the address and that the VSCU is running.');
    }
  }

  /// initializer/selectInitInfo: activates PIN + branch + device serial. 902 = already installed (fine).
  static Future<VscuResult> initialise() async {
    final res = await call('initializer/selectInitInfo', {'dvcSrlNo': serial});
    final installed = res.code == '902' || RegExp(r'device is installed|already', caseSensitive: false).hasMatch(res.msg);
    if (!res.ok && !installed) return res;
    if (res.ok) {
      final info = res.data['info'] is Map ? Map<String, dynamic>.from(res.data['info'] as Map) : <String, dynamic>{};
      String v(String k) => info[k] == null ? '' : '${info[k]}';
      await _s.set('etr_taxpayer', v('taxprNm'));
      await _s.set('etr_branch', v('bhfNm'));
      await _s.set('etr_location', [v('locDesc'), v('sctrNm'), v('dstrtNm'), v('prvncNm')].where((e) => e.isNotEmpty).join(', '));
      await _s.set('etr_device_id', v('dvcId'));
      if (v('sdcId').isNotEmpty) await _s.set('etr_sdc', v('sdcId'));
      if (v('mrcNo').isNotEmpty) await _s.set('etr_mrc', v('mrcNo'));
      // KRA already holds invoices up to lastSaleInvcNo: carry on after it
      final last = int.tryParse(v('lastSaleInvcNo')) ?? 0;
      if (await nextInvoice() <= last) await setNextInvoice(last + 1);
    }
    await _s.setFlag('etr_init', true);
    await _s.set('etr_init_at', nowIso());
    if (_s.taxPin.isEmpty) await _s.set('tax_pin', tin);
    return res;
  }

  // ---------------------------------------------------------------------------
  // Items
  // ---------------------------------------------------------------------------
  /// KRA item code: origin + type + packaging + quantity unit, padded with the product number to 20 characters.
  static String itemCodeFor(Map<String, Object?> p) {
    final origin = _or(p['origin'], 'KE'), type = _or(p['item_type'], '2'), pkg = _or(p['pkg_unit'], 'NT'), qu = _or(p['qty_unit'], 'U');
    var seq = n(p['id']);
    if ('$origin$type$pkg$qu'.length + '$seq'.length > 20) seq = seq % 10000000000;
    return makeItemCode(origin: origin, type: type, pkg: pkg, qty: qu, seq: seq);
  }

  static String _or(Object? v, String def) => s(v).trim().isEmpty ? def : s(v).trim();

  /// items/saveItems: register (or update) a product with KRA. Saves the result on the product.
  static Future<VscuResult> saveItem(Map<String, Object?> p) async {
    final db = await Db.get();
    final cls = _or(p['cls_cd'], defaultClass);
    var code = s(p['item_cd']);
    if (code.isEmpty) code = itemCodeFor(p);
    if (cls.isEmpty) {
      final r = VscuResult(ok: false, msg: 'Choose the KRA item class (on the product, or a default in the KRA device set-up).');
      await db.update('products', {'item_cd': code, 'kra_reg': 0, 'kra_err': r.msg}, where: 'id = ?', whereArgs: [p['id']]);
      return r;
    }
    final user = Session.i.name.isEmpty ? appTitle : Session.i.name;
    final res = await call('items/saveItems', {
      'itemCd': code,
      'itemClsCd': cls,
      'itemTyCd': _or(p['item_type'], '2'),
      'itemNm': s(p['name']),
      'orgnNatCd': _or(p['origin'], 'KE'),
      'pkgUnitCd': _or(p['pkg_unit'], 'NT'),
      'qtyUnitCd': _or(p['qty_unit'], 'U'),
      'taxTyCd': taxCdOf(p),
      'bcd': s(p['barcode']).isEmpty ? null : s(p['barcode']),
      'dftPrc': k2(d(p['price'])),
      'isrcAplcbYn': 'N',
      'useYn': 'Y',
      'regrId': '1',
      'regrNm': user,
      'modrId': '1',
      'modrNm': user,
    });
    await db.update('products', {'item_cd': code, 'cls_cd': cls, 'kra_reg': res.ok ? 1 : 0, 'kra_err': res.ok ? '' : res.message},
        where: 'id = ?', whereArgs: [p['id']]);
    return res;
  }

  /// Registers every product of the sale that KRA does not know yet. Returns an error, or null.
  static Future<String?> _registerItems(Iterable<int> ids) async {
    for (final id in ids.toSet()) {
      final p = await Db.one('SELECT * FROM products WHERE id = ?', [id]);
      if (p == null || n(p['kra_reg']) == 1) continue;
      final r = await saveItem(p);
      if (!r.ok) return '"${p['name']}" is not registered with KRA: ${r.message}';
    }
    return null;
  }

  /// Registers all products not yet registered. Returns (done, failed).
  static Future<(int, int)> registerAll() async {
    var ok = 0, bad = 0;
    for (final p in await Db.q('SELECT * FROM products WHERE active = 1 AND kra_reg = 0')) {
      (await saveItem(p)).ok ? ok++ : bad++;
    }
    return (ok, bad);
  }

  /// itemClass/selectItemsClass: KRA item classifications for the picker.
  static Future<VscuResult> refreshItemClasses() async {
    final res = await call('itemClass/selectItemsClass', {'lastReqDt': '20180101000000'});
    if (res.code == '001') return VscuResult(ok: true, code: '001', msg: 'No classifications returned');
    if (!res.ok) return res;
    final list = res.data['itemClsList'] is List ? res.data['itemClsList'] as List : const [];
    final db = await Db.get();
    await db.transaction((tx) async {
      final b = tx.batch();
      for (final e in list) {
        if (e is! Map) continue;
        b.insert('item_classes', {
          'cd': '${e['itemClsCd']}', 'nm': '${e['itemClsNm'] ?? ''}', 'lvl': int.tryParse('${e['itemClsLvl'] ?? 0}') ?? 0,
          'tax': e['taxTyCd'] == null ? '' : '${e['taxTyCd']}',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await b.commit(noResult: true);
    });
    return VscuResult(ok: true, code: res.code, msg: '${list.length} classes saved');
  }

  // ---------------------------------------------------------------------------
  // Signing
  // ---------------------------------------------------------------------------
  /// An invoice of this handheld whose VSCU answer never arrived: it must be re-sent before any new one.
  static Future<Map<String, Object?>?> pending() =>
      Db.one("SELECT * FROM etr_sales WHERE status = 'pending' AND device_no = ? ORDER BY id LIMIT 1", [Db.deviceNo]);

  static Future<Map<String, Object?>?> forSale(int saleId) => Db.one('SELECT * FROM etr_sales WHERE id = ?', [saleId]);

  /// KRA payment type from how the customer paid.
  static String paymentCode(List<Pay> pays) {
    final kinds = {for (final p in pays) if (p.amount > 0.004) p.kind};
    if (kinds.length == 1) {
      return switch (kinds.first) { 'cash' => '01', 'credit' => '02', 'card' => '05', 'mpesa' => '06', _ => '07' };
    }
    if (kinds.length == 2 && kinds.contains('cash') && kinds.contains('credit')) return '03';
    return '07';
  }

  static String _number(String prefix, int invc) => '$prefix-$bhfId-${invc.toString().padLeft(6, '0')}';

  static SaleLineCalc _calc({required int productId, required Map<String, Object?> p, required String name, required String tax,
      required double qty, required double price, required double discount}) {
    final gross = k2(qty * price);
    return SaleLineCalc(
      itemId: productId,
      itemCd: s(p['item_cd']).isEmpty ? itemCodeFor({...p, 'id': productId}) : s(p['item_cd']),
      itemClsCd: _or(p['cls_cd'], defaultClass),
      name: name,
      barcode: s(p['barcode']),
      pkgUnit: _or(p['pkg_unit'], 'NT'),
      qtyUnit: _or(p['qty_unit'], 'U'),
      tax: tax,
      qty: qty,
      priceIncl: price,
      discountRate: gross == 0 ? 0 : discount * 100 / gross,
    );
  }

  static Map<String, Object?> _row(Map<String, dynamic> payload, {required String kind, required String status, String error = ''}) => {
        'invc_no': payload['invcNo'], 'trd_invc_no': payload['trdInvcNo'], 'kind': kind, 'org_invc_no': payload['orgInvcNo'] ?? 0,
        'rfd_rsn': payload['rfdRsnCd'] ?? '', 'status': status, 'error': error, 'pmt_ty_cd': payload['pmtTyCd'],
        'cust_tin': payload['custTin'] ?? '', 'cust_nm': payload['custNm'] ?? '', 'tin': tin, 'bhf_id': bhfId,
        'payload': jsonEncode(payload), 'created_at': nowIso(), 'device_no': Db.deviceNo,
      };

  static Map<String, Object?> _signedFields(VscuResult res) {
    final dd = res.data;
    String v(String k) => dd[k] == null ? '' : '${dd[k]}';
    final pub = [v('vsdcRcptPbctDate'), v('VSCURcptPbctDate'), v('sdcDateTime')].firstWhere((e) => e.isNotEmpty, orElse: () => etimsDateTime(DateTime.now()));
    return {
      'status': 'signed', 'error': '', 'response': jsonEncode(res.raw),
      'rcpt_no': int.tryParse(v('rcptNo')) ?? int.tryParse(v('curRcptNo')), 'tot_rcpt_no': int.tryParse(v('totRcptNo')),
      'intrl_data': v('intrlData'), 'rcpt_sign': v('rcptSign'),
      'sdc_id': v('sdcId').isNotEmpty ? v('sdcId') : sdcId, 'mrc_no': v('mrcNo').isNotEmpty ? v('mrcNo') : mrcNo, 'sdc_date': pub,
    };
  }

  static Future<void> _keepScu(VscuResult res) async {
    final sdc = '${res.data['sdcId'] ?? ''}', mrc = '${res.data['mrcNo'] ?? ''}';
    if (sdcId.isEmpty && sdc.isNotEmpty) await _s.set('etr_sdc', sdc);
    if (mrcNo.isEmpty && mrc.isNotEmpty) await _s.set('etr_mrc', mrc);
  }

  static Future<void> _save(int id, Map<String, Object?> row) async =>
      (await Db.get()).insert('etr_sales', {...row, 'id': id}, conflictAlgorithm: ConflictAlgorithm.replace);

  /// A refusal: what to tell the cashier (and move the counter when KRA says so).
  static Future<String> _refusal(int invc, VscuResult res) async {
    if (res.duplicate) {
      await _moveOn(invc);
      return 'Invoice number $invc was already used at KRA, so the app moved on to ${invc + 1}. Tap the button again to sign with the next number.';
    }
    final want = expectedInvoiceNo(res.msg);
    if (want != null && want > 0) {
      await setNextInvoice(want);
      return 'KRA expects invoice number $want; the app now uses it. Tap the button again.';
    }
    return 'KRA refused: ${res.message}';
  }

  /// The number to try next. Several handhelds may sign on the same KRA PIN + branch through the same VSCU,
  /// so they share one invoice sequence: never go below a number another handheld has already used (their
  /// invoices arrive here by sync).
  static Future<int> _startNumber() async {
    final mine = await nextInvoice();
    final seen = n((await Db.one("SELECT MAX(invc_no) m FROM etr_sales WHERE tin = ? AND bhf_id = ? AND status IN ('signed', 'pending')",
        [tin, bhfId]))?['m']);
    return mine > seen ? mine : seen + 1;
  }

  /// Sends a new invoice. When another handheld took the number first (not synced here yet), the VSCU answers
  /// "already used" or "expected N": the number moves on and the invoice is sent again by itself.
  static Future<(Map<String, dynamic>, VscuResult)> _sendNew(Map<String, dynamic> Function(int invc) make) async {
    var invc = await _startNumber();
    for (var tries = 1;; tries++) {
      final payload = make(invc);
      final res = await call('trnsSales/saveSales', payload);
      if (res.ok || res.noAnswer || tries >= 30) return (payload, res);
      if (res.duplicate) {
        await _moveOn(invc);
        final nx = await _startNumber();
        invc = nx > invc ? nx : invc + 1;
        continue;
      }
      final want = expectedInvoiceNo(res.msg);
      if (want != null && want > 0 && want != invc) {
        await setNextInvoice(want);
        invc = want;
        continue;
      }
      return (payload, res);
    }
  }

  /// Sign the cart with KRA, then save it here. Returns the sale id and a warning when KRA did not answer.
  static Future<(int, String?)> sell(Cart cart, List<Pay> pays) async {
    if (!ready) throw SaleError('The KRA device is not set up yet. A technician sets it up in More > KRA eTIMS device.');
    final waiting = await pending();
    if (waiting != null) {
      throw SaleError('KRA invoice ${waiting['trd_invc_no']} is still waiting for the VSCU. Open More > KRA eTIMS device and tap Retry first.');
    }
    await Sales.validate(cart, pays); // stock, credit limit, payments: refused here before KRA is asked
    final reg = await _registerItems(cart.lines.map((l) => l.productId));
    if (reg != null) throw SaleError(reg);
    final lines = <SaleLineCalc>[];
    for (final l in cart.lines) {
      final p = await Db.one('SELECT * FROM products WHERE id = ?', [l.productId]) ?? <String, Object?>{};
      lines.add(_calc(productId: l.productId, p: p, name: l.name, tax: l.taxCd, qty: l.qty, price: l.price, discount: l.discount));
    }
    final cust = cart.customerId == null ? null : await Db.one('SELECT name, phone, tax_pin FROM customers WHERE id = ?', [cart.customerId]);
    final when = DateTime.now();
    final (payload, res) = await _sendNew((invc) => buildSalePayload(
          tin: tin, bhfId: bhfId, invcNo: invc, trdInvcNo: _number('INV', invc), lines: lines, paymentCode: paymentCode(pays),
          when: when, custTin: s(cust?['tax_pin']).trim().toUpperCase(), custNm: s(cust?['name']).trim(),
          custMblNo: s(cust?['phone']).trim(), userId: '${Session.i.userId}', userName: Session.i.name.isEmpty ? appTitle : Session.i.name,
          taxableInclVat: inclVat,
        ));
    final invc = n(payload['invcNo']);
    if (!res.ok && !res.noAnswer) throw SaleError(await _refusal(invc, res));
    late int saleId;
    try {
      saleId = await Sales.checkout(cart, pays);
    } catch (e) {
      // KRA has (or may have) the invoice but it could not be saved here: keep the evidence for support
      await Db.setKv('etr_orphan_$invc', jsonEncode({'payload': payload, 'response': res.raw, 'error': '$e'}));
      if (res.ok) await _moveOn(invc);
      throw SaleError('KRA ${res.ok ? 'signed' : 'may have received'} invoice $invc, but the sale could not be saved here: $e. Tell BRV support.');
    }
    if (res.ok) {
      await _save(saleId, {..._row(payload, kind: 'S', status: 'signed'), ..._signedFields(res)});
      await _moveOn(invc);
      await _keepScu(res);
      return (saleId, null);
    }
    await _save(saleId, _row(payload, kind: 'S', status: 'pending', error: res.message));
    return (saleId, '${res.message}\nThe sale is saved and waiting for KRA. Retry it in More > KRA eTIMS device: it keeps the same '
        'invoice number, so it is never signed twice. New sales wait until it is signed.');
  }

  /// Full refund as a KRA credit note: signed first, then the refund is saved (stock back, money back).
  static Future<(int, String?)> refund(int saleId, {required String reasonCd, required String note}) async {
    final org = await forSale(saleId);
    if (org == null) return (await Sales.refund(saleId, reason: note), null); // sold before KRA signing (old data)
    if (s(org['status']) != 'signed') throw SaleError('This sale is not signed by KRA. Retry or sign it first (More > KRA eTIMS device).');
    if (!ready) throw SaleError('The KRA device is not set up on this handheld.');
    final waiting = await pending();
    if (waiting != null) throw SaleError('KRA invoice ${waiting['trd_invc_no']} is still waiting. Retry it first.');
    final rows = await Db.q(
        'SELECT l.*, p.item_cd, p.cls_cd, p.barcode, p.pkg_unit, p.qty_unit, p.origin, p.item_type FROM sale_lines l '
        'LEFT JOIN products p ON p.id = l.product_id WHERE l.sale_id = ? ORDER BY l.id',
        [saleId]);
    final lines = [
      for (final l in rows)
        _calc(productId: n(l['product_id']), p: l, name: s(l['name']), tax: taxCdOf(l), qty: d(l['qty']).abs(), price: d(l['price']),
            discount: d(l['discount']).abs()),
    ];
    Map<String, dynamic> op = {};
    try {
      op = Map<String, dynamic>.from(jsonDecode(s(org['payload'])) as Map);
    } catch (_) {}
    final when = DateTime.now();
    final (payload, res) = await _sendNew((invc) => buildSalePayload(
          tin: tin, bhfId: bhfId, invcNo: invc, trdInvcNo: _number('CN', invc), lines: lines, paymentCode: s(org['pmt_ty_cd']),
          when: when, creditNote: true, orgInvcNo: n(org['invc_no']), refundReason: reasonCd, custTin: s(op['custTin']),
          custNm: s(op['custNm']), custMblNo: s(op['custMblNo']), userId: '${Session.i.userId}',
          userName: Session.i.name.isEmpty ? appTitle : Session.i.name, taxableInclVat: inclVat,
        ));
    final invc = n(payload['invcNo']);
    if (!res.ok && !res.noAnswer) throw SaleError(await _refusal(invc, res));
    final refundId = await Sales.refund(saleId, reason: note);
    if (res.ok) {
      await _save(refundId, {..._row(payload, kind: 'R', status: 'signed'), ..._signedFields(res)});
      await _moveOn(invc);
      return (refundId, null);
    }
    await _save(refundId, _row(payload, kind: 'R', status: 'pending', error: res.message));
    return (refundId, '${res.message}\nThe refund is saved and its credit note is waiting for KRA. Retry it in More > KRA eTIMS device.');
  }

  /// Re-send a waiting invoice with the same number and data. Returns null when signed, else what happened.
  static Future<String?> retry(int id) async {
    final row = await forSale(id);
    if (row == null) return 'Not found.';
    Map<String, dynamic> payload;
    try {
      payload = Map<String, dynamic>.from(jsonDecode(s(row['payload'])) as Map);
    } catch (_) {
      return 'The saved invoice data is damaged.';
    }
    final invc = n(payload['invcNo']);
    final res = await call('trnsSales/saveSales', payload);
    final db = await Db.get();
    if (res.ok) {
      await db.update('etr_sales', _signedFields(res), where: 'id = ?', whereArgs: [id]);
      await _moveOn(invc);
      await _keepScu(res);
      return null;
    }
    if (res.noAnswer) {
      await db.update('etr_sales', {'error': res.message}, where: 'id = ?', whereArgs: [id]);
      return '${res.message} It is still waiting (same invoice number).';
    }
    if (res.duplicate) {
      // another handheld on this PIN + branch signed this number (its invoice has synced here): ours was
      // never signed, so sign it again with the next free number
      final other = await Db.one(
          "SELECT id FROM etr_sales WHERE tin = ? AND bhf_id = ? AND invc_no = ? AND id <> ? AND status = 'signed'", [tin, bhfId, invc, id]);
      if (other != null) {
        await _moveOn(invc);
        await db.update('etr_sales', {'status': 'failed'}, where: 'id = ?', whereArgs: [id]);
        return signAgain(id);
      }
    }
    final msg = await _refusal(invc, res);
    await db.update('etr_sales', {'status': 'failed', 'error': msg}, where: 'id = ?', whereArgs: [id]);
    return '$msg\nUse "Sign again" to sign it with a new invoice number.';
  }

  /// A refused invoice (its number was not used): sign the same sale again with the next number.
  static Future<String?> signAgain(int id) async {
    final row = await forSale(id);
    if (row == null) return 'Not found.';
    final waiting = await pending();
    if (waiting != null && n(waiting['id']) != id) return 'KRA invoice ${waiting['trd_invc_no']} is waiting. Retry it first.';
    final payload = Map<String, dynamic>.from(jsonDecode(s(row['payload'])) as Map);
    final invc = await _startNumber();
    final credit = s(row['kind']) == 'R';
    payload['invcNo'] = invc;
    payload['trdInvcNo'] = _number(credit ? 'CN' : 'INV', invc);
    await (await Db.get()).update('etr_sales',
        {'invc_no': invc, 'trd_invc_no': payload['trdInvcNo'], 'payload': jsonEncode(payload), 'status': 'pending', 'error': ''},
        where: 'id = ?', whereArgs: [id]);
    return retry(id);
  }

  /// A sale KRA would not sign and that should not stand: undo it here (stock and money back, no credit note).
  static Future<void> cancelUnsigned(int id) async {
    final row = await forSale(id);
    if (row == null || s(row['kind']) != 'S' || s(row['status']) != 'failed') throw SaleError('Only a sale KRA refused can be cancelled.');
    await Sales.refund(id, reason: 'Cancelled: not signed by KRA');
    await (await Db.get()).update('etr_sales', {'status': 'cancelled'}, where: 'id = ?', whereArgs: [id]);
  }
}
