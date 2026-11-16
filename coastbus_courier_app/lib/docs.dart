import 'codes.dart';
import 'fmt.dart';
import 'master.dart';
import 'ops.dart';
import 'printer.dart';
import 'session.dart';

const payLabels = {'cash': 'Cash', 'mpesa_code': 'M-Pesa', 'mpesa_stk': 'M-Pesa (STK)', 'account': 'Account (invoice)'};

/// The printouts (58 mm or 80 mm thermal).
class Docs {
  static Master get m => Master.i;

  static List<PLine> _head({String? branch}) {
    final c = m.company;
    final hub = m.hub;
    return [
      const PLine.logo(),
      PLine.center(s(c['name']).toUpperCase(), size: 24, bold: true),
      PLine.center('${branch ?? s(hub['name'])} Branch${s(hub['address']).isNotEmpty ? ' - ${hub['address']}' : ''}', size: 17),
      if (s(hub['phone']).isNotEmpty || s(c['phone']).isNotEmpty) PLine.center('Tel: ${s(hub['phone']).isNotEmpty ? hub['phone'] : c['phone']}', size: 17),
      if (s(c['vat']).isNotEmpty) PLine.center('PIN: ${c['vat']}', size: 17, bold: true),
      const PLine.dash(),
    ];
  }

  static String _link(Map<String, dynamic> w) => '${s(m.cfg['track_url'])}${w['tracking_token']}';

  static List<PLine> receipt(Map<String, dynamic> w, {bool copy = false}) {
    final account = w['payment_mode'] == 'account';
    return [
      ..._head(),
      if (copy) const PLine.center('*** COPY ***', bold: true),
      PLine.row('Date:', dtOdoo(s(w['booked_at']))),
      PLine.row('Waybill:', s(w['name']), bold: true),
      PLine.row('Clerk:', s(w['booked_by']).isEmpty ? Session.i.name : s(w['booked_by'])),
      const PLine.dash(),
      const PLine.left('SENDER:', size: 17, bold: true),
      PLine.left('${w['sender_name']} (${maskPhone(localPhone(s(w['sender_phone'])))})'),
      const PLine.left('RECEIVER:', size: 17, bold: true),
      PLine.left('${w['receiver_name']} (${maskPhone(localPhone(s(w['receiver_phone'])))})'),
      PLine.left('TO: ${m.hubLabel(n(w['destination_hub_id'])).toUpperCase()}', size: 21, bold: true),
      const PLine.dash(),
      PLine.row('Contents:', s(w['description'])),
      PLine.row('Pieces:', '${w['pieces']}'),
      PLine.row('Weight:', kg(d(w['weight']))),
      if (d(w['vol_weight']) > 0) PLine.row('Volumetric:', kg(d(w['vol_weight']))),
      PLine.row('Chargeable:', kg(d(w['chargeable_weight']))),
      if (d(w['declared_value']) > 0) PLine.row('Declared value:', money(d(w['declared_value']))),
      if (w['fragile'] == true) const PLine.center('FRAGILE', bold: true),
      const PLine.dash(),
      PLine.row('Freight:', money(d(w['fare']))),
      if (d(w['insurance']) > 0) PLine.row('Insurance:', money(d(w['insurance']))),
      if (d(w['vat_amount']) > 0) PLine.row('VAT included:', money(d(w['vat_amount']))),
      PLine.row(account ? 'TOTAL (on account):' : 'TOTAL PAID:', money(d(w['total'])), size: 22, bold: true),
      PLine.row('Payment:', payLabels[w['payment_mode']] ?? s(w['payment_mode'])),
      if (s(w['payment_ref']).isNotEmpty) PLine.row('Ref:', s(w['payment_ref'])),
      if (account) PLine.row('Account:', s(w['account_name'])),
      const PLine.dash(),
      const PLine.center('Track your parcel', size: 17, bold: true),
      PLine.qr(_link(w), size: 170),
      PLine.center('Scan the QR, or use the link in your SMS', size: 14),
      const PLine.gap(4),
      const PLine.center('The receiver gets a collection code by SMS when the parcel arrives.', size: 15),
      if (s(m.cfg['receipt_footer']).isNotEmpty) PLine.center(s(m.cfg['receipt_footer']), size: 15),
      if (s(m.cfg['terms']).isNotEmpty) PLine.center(s(m.cfg['terms']), size: 15),
    ];
  }

  static List<PLine> sticker(Map<String, dynamic> w, int piece) {
    final pcs = n(w['pieces']) < 1 ? 1 : n(w['pieces']);
    final code = pieceCode(s(w['name']), piece, pcs);
    return [
      PLine.row(s(w['name']), 'FROM: ${m.hubCodeOf(n(w['origin_hub_id']))}', size: 18, bold: true),
      const PLine.gap(4),
      PLine.big(m.hubLabel(n(w['destination_hub_id'])).toUpperCase(), size: 38),
      PLine.left('TO: ${w['receiver_name']} (${maskPhone(localPhone(s(w['receiver_phone'])))})', size: 18),
      PLine.row('PCS: $piece of $pcs', 'WT: ${kg(d(w['weight']))}', size: 20, bold: true),
      PLine.left('CONTENTS: ${w['description']}', size: 17),
      if (w['fragile'] == true) const PLine.big('FRAGILE', size: 26),
      const PLine.gap(4),
      PLine.qr(code, size: 190),
      PLine.barcode(code, size: 64),
      PLine.center(code, size: 20, bold: true),
      PLine.center('${dtOdoo(s(w['booked_at']))}  ${m.hubLabel(n(w['origin_hub_id'])).toUpperCase()}', size: 15),
    ];
  }

  static List<PLine> departure(Map<String, dynamic> mf) {
    final ls = Ops.lines(mf).where((l) => l['extra'] != true).toList();
    final pieces = ls.fold<int>(0, (a, l) => a + piecesOf(l['loaded']).length);
    final weight = ls.fold<double>(0, (a, l) => a + d(l['weight']));
    return [
      ..._head(),
      const PLine.center('DRIVER DEPARTURE MANIFEST', size: 21, bold: true),
      const PLine.dash(),
      PLine.row('Manifest:', s(mf['name']), bold: true),
      PLine.row('From:', m.hubLabel(n(mf['origin_hub_id']))),
      PLine.row('Final stop:', m.hubLabel(n(mf['destination_hub_id']))),
      PLine.row('Vehicle:', s(mf['vehicle'])),
      PLine.row('Driver:', s(mf['driver'])),
      PLine.row('Departed:', dtOdoo(s(mf['departure_time']))),
      const PLine.dash(),
      PLine.row('WAYBILLS:', '${ls.length}', bold: true),
      PLine.row('PIECES LOADED:', '$pieces', bold: true),
      PLine.row('WEIGHT:', kg(weight)),
      const PLine.dash(),
      for (var i = 0; i < ls.length; i++)
        PLine.left('${i + 1}. ${ls[i]['name']} → ${m.hubCodeOf(n(ls[i]['destination_hub_id']))}  ${piecesOf(ls[i]['loaded']).length}/${ls[i]['pieces']}pc  ${kg(d(ls[i]['weight']))}',
            size: 16),
      const PLine.dash(),
      PLine.left('I, ${mf['driver']}, confirm that the $pieces pieces listed above were scanned and loaded into vehicle ${mf['vehicle']} under my custody.',
          size: 16),
      const PLine.sign('Driver signature'),
      PLine.sign('Dispatcher: ${Session.i.name}'),
      const PLine.center('Scan at the destination', size: 15),
      PLine.qr(s(mf['name']), size: 140),
    ];
  }

  static List<PLine> clearance(Map<String, dynamic> mf, int received) => [
        ..._head(),
        const PLine.center('DRIVER CLEARANCE', size: 22, bold: true),
        const PLine.dash(),
        PLine.row('Manifest:', s(mf['name']), bold: true),
        PLine.row('Vehicle:', s(mf['vehicle'])),
        PLine.row('Driver:', s(mf['driver'])),
        PLine.row('Station:', m.hubName),
        PLine.row('Date:', dt(DateTime.now())),
        const PLine.dash(),
        PLine.big('ALL $received PIECES RECEIVED', size: 24),
        const PLine.left('Loaded and offloaded counts match. The driver is cleared for this manifest at this station.', size: 16),
        PLine.sign('Received by: ${Session.i.name}'),
        const PLine.sign('Driver signature'),
      ];

  static List<PLine> docket(Map<String, dynamic> mf, List<(Map<String, dynamic>, Set<int>)> short, Map<String, Map<String, dynamic>> wbs,
          {required int expected, required int received, String supervisor = ''}) =>
      [
        ..._head(),
        const PLine.big('*** SHORTAGE ALERT ***', size: 24),
        PLine.row('Date:', dt(DateTime.now())),
        PLine.row('Station:', m.hubName),
        PLine.row('Manifest:', s(mf['name']), bold: true),
        PLine.row('From:', m.hubLabel(n(mf['origin_hub_id']))),
        PLine.row('Vehicle:', s(mf['vehicle'])),
        PLine.row('Driver:', s(mf['driver'])),
        const PLine.dash(),
        PLine.row('Expected pieces:', '$expected', bold: true),
        PLine.row('Received pieces:', '$received', bold: true),
        PLine.left('MISSING (${short.length} waybill${short.length == 1 ? '' : 's'}):', bold: true),
        for (final x in short) ...[
          PLine.left('${x.$1['name']}  piece${x.$2.length == 1 ? '' : 's'} ${piecesText(x.$2)} of ${x.$1['pieces']}', bold: true, size: 17),
          if (wbs[x.$1['name']] != null) ...[
            PLine.left('  ${wbs[x.$1['name']]!['description']} · ${kg(d(wbs[x.$1['name']]!['weight']))}', size: 15),
            PLine.left('  Sender: ${wbs[x.$1['name']]!['sender_name']}  Receiver: ${wbs[x.$1['name']]!['receiver_name']}', size: 15),
            if (d(wbs[x.$1['name']]!['declared_value']) > 0) PLine.left('  Declared value: ${money(d(wbs[x.$1['name']]!['declared_value']))}', size: 15),
          ],
          PLine.left('  Loaded scan: ${dtOdoo(s(x.$1['loaded_at']))} (custody: ${mf['driver']})', size: 15),
        ],
        const PLine.dash(),
        PLine.left('These pieces were scanned onto vehicle ${mf['vehicle']} at loading and were not offloaded here. An investigation is opened in Odoo.',
            size: 16),
        PLine.sign('Driver: ${mf['driver']}'),
        PLine.sign('Receiving officer: ${Session.i.name}'),
        if (supervisor.isNotEmpty) PLine.sign('Supervisor: $supervisor'),
      ];

  static List<PLine> collection(Map<String, dynamic> w, {required String name, required String idNo, required String method}) => [
        ..._head(),
        const PLine.center('PARCEL COLLECTED', size: 22, bold: true),
        const PLine.dash(),
        PLine.row('Waybill:', s(w['name']), bold: true),
        PLine.row('From:', m.hubLabel(n(w['origin_hub_id']))),
        PLine.row('Sender:', s(w['sender_name'])),
        PLine.row('Contents:', s(w['description'])),
        PLine.row('Pieces:', '${w['pieces']}'),
        const PLine.dash(),
        PLine.row('Collected by:', name, bold: true),
        PLine.row('ID no.:', idNo.isEmpty ? '-' : idNo),
        PLine.row('Verified by:', method == 'otp' ? 'SMS code' : 'ID + supervisor'),
        PLine.row('Date:', dt(DateTime.now())),
        PLine.row('Released by:', Session.i.name),
        const PLine.dash(),
        const PLine.sign('Receiver signature'),
        const PLine.center('Thank you for using our courier.', size: 16),
      ];

  static List<PLine> day(List<Map<String, dynamic>> wbs, String who, DateTime date) {
    final live = wbs.where((w) => w['state'] != 'cancelled').toList();
    final by = <String, double>{};
    final cnt = <String, int>{};
    for (final w in live) {
      final k = s(w['payment_mode']);
      by[k] = (by[k] ?? 0) + d(w['total']);
      cnt[k] = (cnt[k] ?? 0) + 1;
    }
    final total = live.fold<double>(0, (a, w) => a + d(w['total']));
    return [
      ..._head(),
      const PLine.center('DAY SUMMARY', size: 22, bold: true),
      PLine.row('Date:', dt(date, time: false)),
      PLine.row('Clerk:', who),
      PLine.row('Printed:', dt(DateTime.now())),
      const PLine.dash(),
      PLine.row('Waybills:', '${live.length}', bold: true),
      for (final k in by.keys) PLine.row('${payLabels[k] ?? k} (${cnt[k]}):', money(by[k]!)),
      PLine.row('TOTAL:', money(total), size: 22, bold: true),
      PLine.row('CASH TO HAND OVER:', money(by['cash'] ?? 0), bold: true),
      if (wbs.length != live.length) PLine.row('Cancelled:', '${wbs.length - live.length}'),
      const PLine.dash(),
      for (final w in wbs) PLine.row('${w['name']} ${m.hubCodeOf(n(w['destination_hub_id']))}${w['state'] == 'cancelled' ? ' (X)' : ''}', money(d(w['total']), symbol: false), size: 15),
      const PLine.dash(),
      const PLine.sign('Clerk signature'),
      const PLine.sign('Received by (cash)'),
    ];
  }
}
