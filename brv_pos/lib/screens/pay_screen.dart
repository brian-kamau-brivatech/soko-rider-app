import 'package:flutter/material.dart';
import '../db.dart';
import '../kra.dart';
import '../receipt.dart';
import '../sales.dart';
import '../ui.dart';
import 'sell_screen.dart';

/// Take payment, sign the sale with the VSCU and print the receipt.
/// Pops true when the sale is signed (the cart is then cleared).
class PayScreen extends StatefulWidget {
  const PayScreen({super.key});
  @override
  State<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends State<PayScreen> {
  String _pmt = '01';
  final _tendered = TextEditingController();
  final _custTin = TextEditingController();
  final _custNm = TextEditingController();
  final _custMbl = TextEditingController();
  bool _showCustomer = false;
  bool _busy = false;

  double get _total => Cart.i.total;
  double get _given => double.tryParse(_tendered.text.trim().replaceAll(',', '')) ?? 0;

  @override
  void dispose() {
    for (final c in [_tendered, _custTin, _custNm, _custMbl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _charge() async {
    final tin = _custTin.text.trim().toUpperCase();
    if (tin.isNotEmpty && !RegExp(r'^[A-Z]\d{9}[A-Z]$').hasMatch(tin)) {
      toast(context, 'The customer PIN looks wrong (letter, 9 digits, letter).');
      return;
    }
    if (_pmt == '01' && _tendered.text.trim().isNotEmpty && _given < _total) {
      toast(context, 'Cash given is less than the total.');
      return;
    }
    setState(() => _busy = true);
    final out = await Sales.sell(
      lines: Cart.i.calcs(),
      paymentCode: _pmt,
      tendered: _pmt == '01' && _given > 0 ? _given : 0,
      custTin: tin,
      custNm: _custNm.text,
      custMbl: _custMbl.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);

    if (out.ok) {
      final sale = out.sale!;
      Receipt.printSale(sale);
      await _done(sale);
      if (mounted) Navigator.of(context).pop(true);
      return;
    }

    if (out.sale != null && out.sale!.pending) {
      // Sent but no answer: the cart is already saved in the sale.
      await _message('No answer from the VSCU', out.error ?? '', Icons.hourglass_top_rounded, C.amber);
      if (mounted) Navigator.of(context).pop(true);
      return;
    }

    if (out.expectedNo != null) {
      final fix = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.error_outline_rounded, color: C.red, size: 40),
          title: const Text('Sale not signed'),
          content: Text('${out.error}\n\nThe VSCU expects invoice number ${out.expectedNo}. Use it and try again?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Use ${out.expectedNo}')),
          ],
        ),
      );
      if (fix == true) {
        await Db.setNextInvoiceNo(out.expectedNo!);
        await _charge();
      }
      return;
    }
    await _message('Sale not signed', out.error ?? 'Unknown error', Icons.error_outline_rounded, C.red);
  }

  Future<void> _message(String title, String text, IconData icon, Color color) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(icon, color: color, size: 40),
          title: Text(title),
          content: Text(text),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );

  Future<void> _done(Sale sale) => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.verified_rounded, color: C.green, size: 48),
          title: Text('Signed · ${sale.number}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(money(sale.total), style: h(28)),
            if (sale.tendered > sale.total) ...[
              const SizedBox(height: 8),
              Text('Change ${money(sale.tendered - sale.total)}', style: h(20, color: C.green)),
            ],
            const SizedBox(height: 8),
            Text('CU invoice ${sale.row['sdc_id']}/${sale.row['rcpt_no']}', style: const TextStyle(color: C.muted)),
          ]),
          actions: [
            TextButton.icon(
              onPressed: () async {
                final where = await Receipt.savePdf(sale, share: true);
                if (ctx.mounted) toast(ctx, where == null ? 'Could not make the PDF.' : 'PDF saved in Downloads/BRV POS.');
              },
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('PDF'),
            ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('New sale')),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final total = _total;
    final quick = <double>{
      total,
      for (final n in [50, 100, 200, 500, 1000, 2000]) if (n >= total) n.toDouble(),
      ((total / 100).ceil() * 100).toDouble(),
      ((total / 1000).ceil() * 1000).toDouble(),
    }.toList()
      ..sort();
    final change = _given - total;
    return Scaffold(
      appBar: AppBar(title: Text('Payment', style: h(19))),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 30), children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(18)),
            child: Column(children: [
              const Text('TOTAL TO PAY', style: TextStyle(color: Colors.white70, letterSpacing: 1, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(money(total), style: h(34, color: Colors.white)),
              Text('${Cart.i.lines.length} line(s)', style: const TextStyle(color: Colors.white70)),
            ]),
          ),
          const SizedBox(height: 14),
          Section('Paid by', [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final p in Kra.paymentTypes)
                  ChoiceChip(
                    label: Text(p.name),
                    selected: _pmt == p.code,
                    onSelected: (_) => setState(() => _pmt = p.code),
                  ),
              ]),
            ),
          ]),
          if (_pmt == '01')
            Section('Cash given', [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: TextField(
                  controller: _tendered,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: h(20),
                  decoration: field('Amount received', hint: money(total, symbol: false)),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final v in quick)
                    ActionChip(
                      label: Text(money(v, symbol: false)),
                      onPressed: () => setState(() => _tendered.text = v.toStringAsFixed(v % 1 == 0 ? 0 : 2)),
                    ),
                ]),
              ),
              if (_given > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  child: Row(children: [
                    Text(change >= 0 ? 'Change' : 'Short by', style: h(16, color: change >= 0 ? C.green : C.red)),
                    const Spacer(),
                    Text(money(change.abs()), style: h(22, color: change >= 0 ? C.green : C.red)),
                  ]),
                ),
            ]),
          Section('Customer (optional)', [
            SwitchListTile(
              title: const Text('Add customer details'),
              subtitle: const Text('Needed when the customer wants to claim VAT with their PIN.'),
              value: _showCustomer,
              onChanged: (v) => setState(() => _showCustomer = v),
            ),
            if (_showCustomer) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                child: TextField(
                    controller: _custTin, textCapitalization: TextCapitalization.characters, decoration: field('Customer KRA PIN')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: TextField(controller: _custNm, textCapitalization: TextCapitalization.words, decoration: field('Customer name')),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(controller: _custMbl, keyboardType: TextInputType.phone, decoration: field('Phone')),
              ),
            ],
          ]),
          const SizedBox(height: 4),
          SizedBox(
            height: 58,
            child: FilledButton.icon(
              onPressed: _busy ? null : _charge,
              style: FilledButton.styleFrom(backgroundColor: C.green),
              icon: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                  : const Icon(Icons.verified_outlined),
              label: Text(_busy ? 'Signing with KRA…' : 'Sign & print', style: h(17, color: Colors.white)),
            ),
          ),
        ]),
      ),
    );
  }
}
