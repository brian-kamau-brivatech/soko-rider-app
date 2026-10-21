import 'package:flutter/material.dart';
import '../api.dart';
import '../receipt.dart';
import '../store.dart';
import '../ui.dart';

/// Shows a POS receipt and prints it on the handheld printer.
class ReceiptScreen extends StatefulWidget {
  final Sale sale;
  final PosSetup? setup;
  final bool autoPrint;
  const ReceiptScreen({super.key, required this.sale, this.setup, this.autoPrint = false});
  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  PosSetup? _setup;
  late Sale _sale = widget.sale;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _setup = widget.setup;
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      if (_sale.lines.isEmpty) {
        final s = await PosApi.sale(Store.i.pin, _sale.id);
        if (mounted) setState(() => _sale = s);
      }
      _setup ??= await PosApi.setup(Store.i.pin);
    } catch (_) {}
    if (widget.autoPrint && mounted) _print();
  }

  Future<void> _print() async {
    setState(() => _printing = true);
    try {
      await Receipt.print(
        _sale,
        shop: _setup?.shopName ?? '',
        phone: _setup?.shopPhone ?? '',
        email: _setup?.shopEmail ?? '',
        header: _setup?.header ?? '',
        footer: _setup?.footer ?? '',
      );
    } catch (e) {
      if (mounted) toast(context, 'Could not print: $e');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _sale;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(s.name, style: h(18)),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: card(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Text(_setup?.shopName.isNotEmpty == true ? _setup!.shopName : 'Soko Express Mtaani', style: h(16))),
            Center(child: Text('Served by ${s.cashier} · ${s.date}', style: const TextStyle(color: C.muted, fontSize: 12.5))),
            const Divider(height: 22, color: C.line),
            if (s.lines.isEmpty)
              const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator(color: C.green)))
            else
              for (final l in s.lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${l.qty == l.qty.roundToDouble() ? l.qty.toStringAsFixed(0) : l.qty} × ${ksh(l.price)}',
                            style: const TextStyle(color: C.muted, fontSize: 12.5)),
                      ]),
                    ),
                    Text(ksh(l.total), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                ),
            const Divider(height: 22, color: C.line),
            Row(children: [Expanded(child: Text('TOTAL', style: h(16))), Text(ksh(s.amount), style: h(18))]),
            const SizedBox(height: 6),
            for (final p in s.payments.where((p) => p.amount > 0))
              Row(children: [
                Expanded(child: Text('${p.method}${p.ref.isEmpty ? '' : ' · ${p.ref}'}', style: const TextStyle(color: C.muted))),
                Text(ksh(p.amount)),
              ]),
            if (s.change > 0)
              Row(children: [const Expanded(child: Text('Change', style: TextStyle(color: C.muted))), Text(ksh(s.change), style: h(14, color: C.green))]),
            if (s.customer.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Customer: ${s.customer}')),
            const SizedBox(height: 8),
            Center(child: Text(s.ref, style: const TextStyle(color: C.muted, fontSize: 12))),
          ]),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 56,
          child: ElevatedButton.icon(
            onPressed: _printing ? null : _print,
            icon: const Icon(Icons.print_rounded),
            label: Text(_printing ? 'Printing…' : 'Print receipt', style: h(16, color: Colors.white)),
            style: ElevatedButton.styleFrom(backgroundColor: C.navy, foregroundColor: Colors.white),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 52,
          child: OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: OutlinedButton.styleFrom(foregroundColor: C.green, side: const BorderSide(color: C.green)),
            child: Text('Done', style: h(15.5, color: C.green)),
          ),
        ),
      ]),
    );
  }
}
