import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import 'db.dart';
import 'kra.dart';
import 'settings.dart';

class VscuResult {
  final bool ok;
  final String code; // KRA resultCd ("000" = success); empty when no answer
  final String msg;
  final Map<String, dynamic> data;
  final Map<String, dynamic>? raw;
  final bool noAnswer; // network problem: outcome unknown
  VscuResult({required this.ok, this.code = '', this.msg = '', this.data = const {}, this.raw, this.noAnswer = false});

  String get message => ok ? (msg.isEmpty ? 'Successful' : msg) : (code.isEmpty ? msg : '$code: $msg');
}

class Vscu {
  static String get _root => Settings.i.root;

  static Future<VscuResult> call(String path, Map<String, dynamic> body, {Duration? timeout}) async {
    final started = DateTime.now();
    final s = Settings.i;
    final payload = {'tin': s.tin, 'bhfId': s.bhfId, ...body};
    VscuResult res;
    try {
      final r = await http
          .post(Uri.parse('$_root/$path'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload))
          .timeout(timeout ?? (path.startsWith('trnsSales') ? const Duration(seconds: 100) : const Duration(seconds: 30)));
      dynamic j;
      try {
        j = jsonDecode(r.body);
      } catch (_) {}
      if (j is! Map) {
        res = VscuResult(ok: false, msg: 'The VSCU did not answer with data (HTTP ${r.statusCode}).');
      } else {
        final m = Map<String, dynamic>.from(j);
        final code = '${m['resultCd'] ?? ''}'; // always a string: "000"
        final data = m['data'] is Map ? Map<String, dynamic>.from(m['data']) : <String, dynamic>{};
        res = VscuResult(ok: code == '000', code: code, msg: '${m['resultMsg'] ?? ''}', data: data, raw: m);
      }
    } on TimeoutException {
      res = VscuResult(ok: false, noAnswer: true, msg: 'No answer from the VSCU in time.');
    } catch (e) {
      res = VscuResult(ok: false, noAnswer: true, msg: 'Cannot reach the VSCU at $_root. Check the internet and the VSCU address.');
    }
    await Db.logCall(path, payload, res.raw ?? {'error': res.msg}, res.ok, res.code, res.msg,
        DateTime.now().difference(started).inMilliseconds);
    return res;
  }

  /// Is the VSCU address reachable at all? Returns (reachable, message).
  static Future<(bool, String)> ping(String url) async {
    final root = url.trim().replaceAll(RegExp(r'/+$'), '');
    final started = DateTime.now();
    try {
      final r = await http.get(Uri.parse(root)).timeout(const Duration(seconds: 8));
      final ms = DateTime.now().difference(started).inMilliseconds;
      return (true, 'Reachable (HTTP ${r.statusCode}, $ms ms)');
    } on TimeoutException {
      return (false, 'No answer within 8 seconds.');
    } catch (_) {
      return (false, 'Cannot connect to $root. Check the address and that the VSCU is running.');
    }
  }

  /// initializer/selectInitInfo: activates this PIN + branch + device serial and
  /// returns the taxpayer details and KRA's last invoice numbers.
  static Future<VscuResult> initialise() async {
    final s = Settings.i;
    final res = await call('initializer/selectInitInfo', {'dvcSrlNo': s.serial});
    if (!res.ok) return res;
    final info = res.data['info'] is Map ? Map<String, dynamic>.from(res.data['info']) : <String, dynamic>{};
    String v(String k) => info[k] == null ? '' : '${info[k]}';
    s.initialised = true;
    s.taxpayerName = v('taxprNm');
    s.branchName = v('bhfNm');
    s.location = [v('locDesc'), v('sctrNm'), v('dstrtNm'), v('prvncNm')].where((e) => e.isNotEmpty).join(', ');
    s.deviceId = v('dvcId');
    if (v('sdcId').isNotEmpty) s.controlUnitId = v('sdcId');
    if (v('mrcNo').isNotEmpty) s.mrcNo = v('mrcNo');
    s.initAt = DateTime.now().toIso8601String();
    s.lastSaleInvcNo = int.tryParse(v('lastSaleInvcNo'));
    if (s.businessName.isEmpty) s.businessName = s.taxpayerName;
    if (s.address.isEmpty) s.address = s.location;
    // KRA already holds invoices up to lastSaleInvcNo: carry on after it.
    final next = (s.lastSaleInvcNo ?? 0) + 1;
    if (await Db.nextInvoiceNo() < next) await Db.setNextInvoiceNo(next);
    await s.save();
    return res;
  }

  /// items/saveItems: register (or update) an item with KRA.
  static Future<VscuResult> saveItem(Map<String, dynamic> item) async {
    final s = Settings.i;
    final user = s.cashier.isEmpty ? 'BRV POS' : s.cashier;
    final res = await call('items/saveItems', {
      'itemCd': item['item_cd'],
      'itemClsCd': item['cls_cd'],
      'itemTyCd': item['item_type'],
      'itemNm': item['name'],
      'orgnNatCd': item['origin'],
      'pkgUnitCd': item['pkg_unit'],
      'qtyUnitCd': item['qty_unit'],
      'taxTyCd': item['tax'],
      'bcd': (item['barcode'] ?? '') == '' ? null : item['barcode'],
      'dftPrc': r2(item['price'] as num),
      'isrcAplcbYn': 'N',
      'useYn': 'Y',
      'regrId': '1',
      'regrNm': user,
      'modrId': '1',
      'modrNm': user,
    });
    final db = await Db.get();
    await db.update('items', {'registered': res.ok ? 1 : 0, 'reg_error': res.ok ? '' : res.message},
        where: 'id = ?', whereArgs: [item['id']]);
    return res;
  }

  /// itemClass/selectItemsClass: KRA item classifications, saved for the item picker.
  static Future<VscuResult> refreshItemClasses() async {
    final res = await call('itemClass/selectItemsClass', {'lastReqDt': '20180101000000'});
    if (!res.ok) return res;
    final list = res.data['itemClsList'] is List ? res.data['itemClsList'] as List : const [];
    final db = await Db.get();
    await db.transaction((tx) async {
      final batch = tx.batch();
      for (final e in list) {
        if (e is! Map) continue;
        batch.insert('item_classes', {
          'cd': '${e['itemClsCd']}',
          'nm': '${e['itemClsNm'] ?? ''}',
          'lvl': int.tryParse('${e['itemClsLvl'] ?? 0}') ?? 0,
          'tax': e['taxTyCd'] == null ? '' : '${e['taxTyCd']}',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    return res;
  }
}
