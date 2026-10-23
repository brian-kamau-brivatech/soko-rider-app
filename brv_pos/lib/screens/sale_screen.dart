import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../db.dart';
import '../kra.dart';
import '../kra_check.dart';
import '../receipt.dart';
import '../sales.dart';
import '../session.dart';
import '../ui.dart';

/// One sale: receipt preview, COPY reprint, PDF, retry and credit note.
class SaleScreen extends StatefulWidget {
  final int saleId;
  const SaleScreen({super.key, required this.saleId});
  @override
  State<SaleScreen> createState() => _SaleScreenState();
}

class _SaleScreenState extends State<SaleScreen> {
  Sale? _sale;
  Uint8List? _png;
  bool _busy = false;
  bool _credited = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _load().then((_) {
      // Look it up on KRA straight away if not confirmed yet.
      if (_sale != null && _sale!.signed && _sale!.kraOk != KraCheck.confirmed) _checkKra(quiet: true);
    });
  }

  Future<void> _checkKra({bool quiet = false}) async {
    if (_sale == null || _checking) return;
    setState(() => _checking = true);
    final st = await KraCheck.check(_sale!);
    if (!mounted) return;
    setState(() => _checking = false);
    await _load();
    if (!quiet && mounted) {
      toast(context, switch (st) {
        KraCheck.confirmed => 'Confirmed: KRA has this receipt.',
        KraCheck.notYet => 'KRA does not show it yet. The VSCU sends sales in the background; check again later.',
        _ => 'Could not reach KRA. Check the internet.',
      });
    }
  }

  Widget _kraCard(Sale s) {
    final ok = s.kraOk == KraCheck.confirmed;
    final when = DateTime.tryParse('${s.row['kra_checked'] ?? ''}');
    String two(int v) => v.toString().padLeft(2, '0');
    final checked = when == null ? 'Not checked yet' : 'Checked ${two(when.day)}/${two(when.month)} ${two(when.hour)}:${two(when.minute)}';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: ok ? C.greenLight : C.amberLight, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(ok ? Icons.cloud_done_rounded : Icons.cloud_upload_rounded, color: ok ? C.green : C.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(ok ? 'Transmitted: KRA has this receipt' : 'Signed by the VSCU · not yet confirmed at KRA',
                style: h(15, color: ok ? C.green : C.amber)),
          ),
        ]),
        const SizedBox(height: 4),
        Text('Invoice ${s.invcNo} · CU ${s.row['sdc_id']}/${s.invcNo} · $checked',
            style: const TextStyle(color: C.ink, fontSize: 12.5)),
        const SizedBox(height: 8),
        Row(children: [
          if (_checking)
            const Padding(padding: EdgeInsets.all(8), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
          else
            TextButton.icon(onPressed: () => _checkKra(), icon: const Icon(Icons.refresh_rounded), label: const Text('Check now')),
          TextButton.icon(
            onPressed: () async {
              final ok = await KraCheck.open(s);
              if (!ok && mounted) toast(context, 'Could not open the browser.');
            },
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Open on KRA'),
          ),
        ]),
      ]),
    );
  }

  Future<void> _load() async {
    final s = await Sale.load(widget.saleId);
    if (s == null) return;
    final png = s.signed ? await Receipt.image(s, copy: true) : null;
    var credited = false;
    if (s.signed && !s.isCredit) {
      final db = await Db.get();
      final r = await db.query('sales',
          columns: ['id'], where: "kind = 'R' AND status = 'signed' AND org_invc_no = ?", whereArgs: [s.invcNo], limit: 1);
      credited = r.isNotEmpty;
    }
    if (mounted) {
      setState(() {
        _sale = s;
        _png = png;
        _credited = credited;
      });
    }
  }

  Future<void> _printCopy() async {
    final s = _sale!;
    setState(() => _busy = true);
    final ok = await Receipt.printSale(s, copy: true);
    if (ok) await Sales.countCopy(s);
    if (!mounted) return;
    setState(() => _busy = false);
    toast(context, ok ? 'COPY printed.' : 'Could not print. Check the printer in Settings.');
    _load();
  }

  Future<void> _pdf(bool share) async {
    setState(() => _busy = true);
    final where = await Receipt.savePdf(_sale!, copy: true, share: share);
    if (!mounted) return;
    setState(() => _busy = false);
    toast(context, where == null ? 'Could not make the PDF.' : 'PDF saved in Downloads/BRV POS.');
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    final out = await Sales.retry(_sale!);
    if (!mounted) return;
    setState(() => _busy = false);
    if (out.ok) {
      Receipt.printSale(out.sale!);
      toast(context, 'Signed. Printing the receipt.');
    } else {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Not signed'),
          content: Text(out.error ?? ''),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    }
    _load();
  }

  Future<void> _discard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this sale?'),
        content: const Text('Only do this if you are sure the VSCU never signed it '
            '(check the VSCU call log). Its invoice number will be used by the next sale.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: C.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancel sale')),
        ],
      ),
    );
    if (ok != true) return;
    await Sales.discard(_sale!);
    _load();
  }

  Future<void> _creditNote() async {
    final s = _sale!;
    var reason = '06';
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Credit note'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Reverses all of ${s.number} (${money(s.total)}) with KRA.'),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: reason,
              isExpanded: true,
              decoration: field('Reason'),
              items: [for (final r in Kra.refundReasons) DropdownMenuItem(value: r.code, child: Text(r.name))],
              onChanged: (v) => set(() => reason = v ?? reason),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Issue credit note')),
          ],
        ),
      ),
    );
    if (go != true) return;
    setState(() => _busy = true);
    final db = await Db.get();
    final lines = <SaleLineCalc>[];
    for (final l in s.lines) {
      final r = await db.query('items', where: 'id = ?', whereArgs: [l['item_id']], limit: 1);
      final it = r.isEmpty ? <String, Object?>{} : r.first;
      lines.add(SaleLineCalc(
        itemId: (l['item_id'] as int?) ?? 0,
        itemCd: '${l['item_cd']}',
        itemClsCd: '${it['cls_cd'] ?? ''}',
        name: '${l['name']}',
        barcode: '${it['barcode'] ?? ''}',
        pkgUnit: '${it['pkg_unit'] ?? 'NT'}',
        qtyUnit: '${it['qty_unit'] ?? 'U'}',
        tax: '${l['tax']}',
        qty: (l['qty'] as num).toDouble(),
        priceIncl: (l['price'] as num).toDouble(),
        discountRate: (l['dc_rt'] as num?)?.toDouble() ?? 0,
      ));
    }
    final out = await Sales.sell(
      lines: lines,
      paymentCode: s.paymentCode,
      custTin: s.customerTin,
      custNm: s.customerName,
      creditNote: true,
      orgInvcNo: s.invcNo,
      refundReason: reason,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (out.ok) {
      Receipt.printSale(out.sale!);
      toast(context, 'Credit note ${out.sale!.number} signed.');
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => SaleScreen(saleId: out.sale!.id)));
    } else {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Credit note not signed'),
          content: Text(out.error ?? ''),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _sale;
    return Scaffold(
      appBar: AppBar(title: Text(s?.number ?? 'Sale')),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 30), children: [
              if (_busy) const LinearProgressIndicator(color: C.brand),
              if (!s.signed)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: s.pending ? C.amberLight : C.redLight, borderRadius: BorderRadius.circular(14)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.pending ? 'Waiting for the VSCU' : 'Not signed by KRA',
                        style: h(16, color: s.pending ? C.amber : C.red)),
                    const SizedBox(height: 4),
                    Text(s.pending
                        ? 'The sale was sent but no answer came back. Retry sends the same invoice '
                            '(number ${s.invcNo}) again, so it is never signed twice.'
                        : 'This sale has no KRA signature and is not a valid receipt.${s.error.isEmpty ? '' : '\n${s.error}'}'),
                    if (s.pending && s.error.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(s.error, style: const TextStyle(color: C.muted, fontSize: 12.5)),
                    ],
                    if (s.pending) ...[
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _retry,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Retry'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        TextButton(onPressed: _busy ? null : _discard, child: const Text('Cancel sale', style: TextStyle(color: C.red))),
                      ]),
                    ],
                  ]),
                ),
              if (s.signed) ...[
                _kraCard(s),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _printCopy,
                      icon: const Icon(Icons.print_rounded),
                      label: const Text('Print copy'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _pdf(false),
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('PDF'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    tooltip: 'Share PDF',
                    onPressed: _busy ? null : () => _pdf(true),
                    icon: const Icon(Icons.share_rounded),
                  ),
                ]),
                if (!s.isCredit && Session.i.admin) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy || _credited ? null : _creditNote,
                    style: OutlinedButton.styleFrom(foregroundColor: C.amber),
                    icon: const Icon(Icons.undo_rounded),
                    label: Text(_credited ? 'Credit note already issued' : 'Credit note (refund)'),
                  ),
                ],
                const SizedBox(height: 14),
              ],
              if (_png != null)
                Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 12, offset: const Offset(0, 4))],
                    ),
                    child: Image.memory(_png!, fit: BoxFit.fitWidth, filterQuality: FilterQuality.medium),
                  ),
                )
              else
                Section('Lines', [
                  for (final l in s.lines)
                    ListTile(
                      dense: true,
                      title: Text('${l['name']}'),
                      subtitle: Text('${qtyText((l['qty'] as num).toDouble())} × ${money((l['price'] as num).toDouble(), symbol: false)}'),
                      trailing: Text(money((l['tot'] as num).toDouble(), symbol: false)),
                    ),
                  ListTile(title: Text('Total', style: h(16)), trailing: Text(money(s.total), style: h(16))),
                ]),
            ]),
    );
  }
}
