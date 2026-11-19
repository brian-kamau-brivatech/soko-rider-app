import 'package:flutter/material.dart';
import '../bus.dart';
import '../config.dart';
import '../db.dart';
import '../etr/etr.dart';
import '../etr/kra.dart' show Kra, Code;
import '../fmt.dart';
import '../perms.dart';
import '../receipt.dart';
import '../sales.dart';
import '../session.dart';
import '../settings.dart';
import '../ui.dart';
import 'sell_screen.dart' show printSale;

class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});
  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  DateTime _day = DateTime.now();
  List<Map<String, Object?>> _rows = [];
  String _q = '';

  @override
  void initState() {
    super.initState();
    dataSettled.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataSettled.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final all = Session.i.can(P.allSales);
    final r = await Db.q(
        'SELECT s.*, u.name AS cashier, c.name AS customer, e.status AS kra FROM sales s LEFT JOIN users u ON u.id = s.user_id '
        'LEFT JOIN etr_sales e ON e.id = s.id '
        'LEFT JOIN customers c ON c.id = s.customer_id WHERE s.day = ? ${all ? '' : 'AND s.user_id = ${Session.i.userId}'} ORDER BY s.id DESC',
        [dayKey(_day)]);
    if (mounted) setState(() => _rows = r);
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = _rows.where((r) => q.isEmpty || s(r['number']).toLowerCase().contains(q) || s(r['customer']).toLowerCase().contains(q)).toList();
    final total = shown.fold<double>(0, (a, r) => a + d(r['total']));
    return Scaffold(
      appBar: AppBar(title: Text(Session.i.can(P.allSales) ? 'Sales' : 'My sales')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            IconButton(onPressed: () { setState(() => _day = _day.subtract(const Duration(days: 1))); _load(); }, icon: const Icon(Icons.chevron_left)),
            Expanded(
              child: TextButton(
                onPressed: () async {
                  final p = await showDatePicker(context: context, initialDate: _day, firstDate: DateTime(2020), lastDate: DateTime.now());
                  if (p != null) {
                    setState(() => _day = p);
                    _load();
                  }
                },
                child: Text(dateText(_day.toIso8601String(), time: false), style: h(16)),
              ),
            ),
            IconButton(onPressed: () { setState(() => _day = _day.add(const Duration(days: 1))); _load(); }, icon: const Icon(Icons.chevron_right)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(decoration: const InputDecoration(hintText: 'Receipt no. or customer', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => _q = v)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Row(children: [Text('${shown.length} receipts', style: muted), const Spacer(), Text(money(total), style: h(16))]),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Empty(Icons.receipt_long_outlined, 'No sales on this day.')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, k) {
                    final r = shown[k];
                    final refund = s(r['kind']) == 'refund';
                    return Container(
                      decoration: box(),
                      child: ListTile(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SaleDetail(saleId: n(r['id'])))),
                        title: Text(s(r['number']), style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${dateText(r['date'])} · ${s(r['cashier'])}${s(r['customer']).isEmpty ? '' : ' · ${s(r['customer'])}'}'),
                        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text(money(d(r['total'])), style: h(14, color: refund ? C.red : C.text)),
                          if (refund) const Pill('Refund', fg: C.red, bg: C.redLight),
                          if (s(r['kra']) == 'pending') const Pill('KRA waiting', fg: C.amber, bg: C.amberLight),
                          if (s(r['kra']) == 'failed') const Pill('Not signed', fg: C.red, bg: C.redLight),
                          if (s(r['state']) == 'refunded') const Pill('Refunded', fg: C.amber, bg: C.amberLight),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

class SaleDetail extends StatefulWidget {
  final int saleId;
  const SaleDetail({super.key, required this.saleId});
  @override
  State<SaleDetail> createState() => _SaleDetailState();
}

class _SaleDetailState extends State<SaleDetail> {
  Map<String, Object?>? _sale;
  List<Map<String, Object?>> _lines = [];
  List<Map<String, Object?>> _pays = [];
  Map<String, Object?>? _etr;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sale = await Sales.sale(widget.saleId);
    final l = await Sales.lines(widget.saleId);
    final p = await Sales.payments(widget.saleId);
    final e = await Etr.forSale(widget.saleId);
    if (mounted) {
      setState(() {
        _sale = sale;
        _lines = l;
        _pays = p;
        _etr = e;
      });
    }
  }

  /// Retry / sign again / cancel an invoice KRA has not signed.
  Future<void> _kra(String what) async {
    setState(() => _busy = true);
    try {
      String? msg;
      if (what == 'retry') msg = await Etr.retry(widget.saleId);
      if (what == 'again') msg = await Etr.signAgain(widget.saleId);
      if (what == 'cancel') {
        if (!await confirm(context, 'Cancel this sale?', 'KRA did not sign it. The stock and money go back as if it was never sold.', ok: 'Cancel sale', danger: true)) return;
        await Etr.cancelUnsigned(widget.saleId);
        msg = 'Cancelled.';
      }
      changed();
      if (msg == null && Settings.i.printAfterSale) await printSale(widget.saleId); // now signed: print the KRA receipt
      if (mounted) toast(context, msg ?? 'Signed by KRA.');
    } on SaleError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
      _load();
    }
  }

  Future<void> _refund() async {
    final sale = _sale!;
    if (!Session.i.can(P.refund)) {
      final pin = await ask(context, 'Manager approval', label: 'PIN of someone allowed to refund', number: true);
      if (pin == null) return;
      final m = await Session.userByPin(pin.trim(), right: P.refund);
      if (m == null) {
        if (mounted) toast(context, 'That PIN cannot approve refunds.');
        return;
      }
    }
    if (!mounted) return;
    // KRA ETR: the refund is a credit note, signed by KRA first; KRA needs a reason code
    Code? code;
    if (isEtrApp && _etr != null) {
      code = await showModalBottomSheet<Code>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text('Credit note reason (KRA)', style: h(17))),
            for (final c in Kra.refundReasons) ListTile(title: Text(c.name), onTap: () => Navigator.pop(ctx, c)),
          ]),
        ),
      );
      if (code == null || !mounted) return;
    }
    final reason = await ask(context, 'Refund ${sale['number']}', label: 'Note', initial: code?.name ?? '', hint: 'e.g. returned, wrong item');
    if (reason == null) return;
    setState(() => _busy = true);
    try {
      String? warning;
      var refundId = 0;
      if (isEtrApp) {
        final r = await Etr.refund(widget.saleId, reasonCd: code?.code ?? '06', note: reason.trim());
        refundId = r.$1;
        warning = r.$2;
      } else {
        refundId = await Sales.refund(widget.saleId, reason: reason.trim());
      }
      changed();
      // the credit note / refund receipt prints by itself (same setting as sale receipts)
      if (Settings.i.printAfterSale && refundId > 0) {
        final ok = await printSale(refundId);
        if (!ok && mounted) toast(context, 'Printer not found. Choose it in More > Printer, then reprint from the refund receipt.');
      }
      if (mounted) toast(context, warning ?? (isEtrApp && _etr != null ? 'Credit note signed by KRA. Stock returned.' : 'Refunded. Stock returned.'));
      _load();
    } on SaleError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sale = _sale;
    return Scaffold(
      appBar: AppBar(title: Text(sale == null ? 'Receipt' : s(sale['number'])), actions: [
        if (sale != null)
          IconButton(
            tooltip: 'Share PDF',
            onPressed: () async {
              final r = await Printer.pdf(Printer.saleLines(sale, _lines, _pays, etr: _etr), s(sale['number']), share: true);
              if (context.mounted && r == null) toast(context, 'Could not make the PDF.');
            },
            icon: const Icon(Icons.share_outlined),
          ),
      ]),
      body: sale == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Container(
                decoration: box(),
                child: Column(children: [
                  KV('Date', dateText(sale['date'])),
                  KV('Served by', s(sale['cashier'])),
                  if (s(sale['customer']).isNotEmpty) KV('Customer', s(sale['customer'])),
                  KV('Location', s(sale['location'])),
                  if (s(sale['note']).isNotEmpty) KV('Note', s(sale['note'])),
                  if (n(sale['copies']) > 0) KV('Reprints', '${n(sale['copies'])}'),
                ]),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: box(),
                child: Column(children: [
                  for (final l in _lines)
                    ListTile(
                      title: Text(s(l['name']), style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${qty(d(l['qty']))} x ${money(d(l['price']), symbol: false)}${d(l['discount']) != 0 ? ' · discount ${money(d(l['discount']).abs(), symbol: false)}' : ''}'),
                      trailing: Text(money(d(l['total']), symbol: false), style: h(14)),
                    ),
                  const Divider(),
                  if (d(sale['tax']) != 0) KV('VAT included', money(d(sale['tax']))),
                  KV('Total', money(d(sale['total'])), bold: true),
                  for (final p in _pays) KV(s(p['name']) + (s(p['ref']).isEmpty || s(p['ref']) == 'refund' ? '' : ' (${s(p['ref'])})'), money(d(p['amount']))),
                  if (d(sale['change']) > 0) KV('Change', money(d(sale['change']))),
                ]),
              ),
              if (_etr != null) ...[
                const SizedBox(height: 12),
                _kraCard(_etr!),
              ],
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () async {
                  final ok = await printSale(widget.saleId, copy: true);
                  if (context.mounted) toast(context, ok ? 'Copy printed.' : 'Printer not found. Choose it in More > Printer.');
                  _load();
                },
                icon: const Icon(Icons.print_outlined),
                label: const Text('Reprint (copy)'),
              ),
              if (s(sale['kind']) == 'sale' && s(sale['state']) != 'refunded') ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _refund,
                  style: OutlinedButton.styleFrom(foregroundColor: C.red),
                  icon: const Icon(Icons.undo_rounded),
                  label: const Text('Refund this sale'),
                ),
              ],
            ]),
    );
  }

  Widget _kraCard(Map<String, Object?> e) {
    final st = s(e['status']);
    final mine = isEtrApp && n(e['device_no']) == Db.deviceNo;
    final (label, fg, bg) = switch (st) {
      'signed' => ('Signed by KRA', C.green, C.greenLight),
      'pending' => ('Waiting for KRA', C.amber, C.amberLight),
      'cancelled' => ('Cancelled (not signed)', C.muted, C.soft),
      _ => ('Not signed by KRA', C.red, C.redLight),
    };
    return Container(
      decoration: box(),
      child: Column(children: [
        ListTile(
          leading: const Icon(Icons.verified_outlined),
          title: Text(s(e['kind']) == 'R' ? 'KRA credit note' : 'KRA invoice', style: const TextStyle(fontWeight: FontWeight.w700)),
          trailing: Pill(label, fg: fg, bg: bg),
        ),
        KV('Invoice', s(e['trd_invc_no'])),
        if (st == 'signed') KV('CU invoice no.', '${s(e['sdc_id'])}/${e['invc_no']}'),
        if (s(e['cust_tin']).isNotEmpty) KV('Customer PIN', s(e['cust_tin'])),
        if (st != 'signed' && s(e['error']).isNotEmpty)
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8), child: Text(s(e['error']), style: const TextStyle(color: C.red))),
        if (mine && st == 'pending')
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: FilledButton.icon(onPressed: _busy ? null : () => _kra('retry'), icon: const Icon(Icons.refresh), label: Text(_busy ? 'Sending...' : 'Retry (same invoice number)')),
          ),
        if (mine && st == 'failed')
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(children: [
              Expanded(child: FilledButton(onPressed: _busy ? null : () => _kra('again'), child: const Text('Sign again'))),
              if (s(e['kind']) == 'S') ...[
                const SizedBox(width: 10),
                Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _kra('cancel'), style: OutlinedButton.styleFrom(foregroundColor: C.red), child: const Text('Cancel sale'))),
              ],
            ]),
          ),
      ]),
    );
  }
}
