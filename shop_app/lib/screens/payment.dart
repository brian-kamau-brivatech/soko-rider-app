import 'dart:async';
import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'receipt_screen.dart';

class CartLine {
  final PosProduct product;
  final double qty;
  CartLine(this.product, this.qty);
  double get total => product.price * qty;
}

/// Take payment with the POS payment methods, then save the sale in Odoo POS.
class PaymentScreen extends StatefulWidget {
  final PosSetup setup;
  final List<CartLine> lines;
  const PaymentScreen({super.key, required this.setup, required this.lines});
  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  late PayMethod _method = widget.setup.methods.first;
  final _cash = TextEditingController();
  final _phone = TextEditingController();
  final _name = TextEditingController();
  // One id per sale, so a retried tap never saves the sale twice.
  final String _uid = 'app-${DateTime.now().microsecondsSinceEpoch}';

  MpesaFound? _found;
  int? _promptTx;
  String _mpesaInfo = '';
  bool _checking = false;
  bool _saving = false;
  Timer? _poll;

  double get _total => double.parse(widget.lines.fold<double>(0, (a, l) => a + l.total).toStringAsFixed(2));
  double get _tendered => double.tryParse(_cash.text.trim()) ?? 0;

  @override
  void dispose() {
    _poll?.cancel();
    _cash.dispose();
    _phone.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _ready {
    if (_method.mpesa) return _found?.found == true;
    if (_method.cash) return _tendered + 0.001 >= _total;
    return true;
  }

  Future<void> _checkMpesa() async {
    if (_phone.text.replaceAll(RegExp(r'[^0-9]'), '').length < 9) {
      toast(context, 'Enter the customer M-Pesa phone number.');
      return;
    }
    setState(() {
      _checking = true;
      _mpesaInfo = '';
    });
    try {
      final f = await PosApi.mpesaCheck(Store.i.pin, _phone.text.trim(), _total);
      setState(() {
        _found = f.found ? f : null;
        _mpesaInfo = f.found
            ? 'Payment found${f.receipt.isEmpty ? '' : ' · ${f.receipt}'}'
            : 'No KSh ${_total.toStringAsFixed(0)} payment from this number yet.';
      });
    } catch (e) {
      setState(() => _mpesaInfo = '$e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _sendPrompt() async {
    if (_phone.text.replaceAll(RegExp(r'[^0-9]'), '').length < 9) {
      toast(context, 'Enter the customer M-Pesa phone number.');
      return;
    }
    setState(() {
      _checking = true;
      _mpesaInfo = 'Sending the M-Pesa prompt…';
      _found = null;
    });
    try {
      _promptTx = await PosApi.mpesaPrompt(Store.i.pin, _phone.text.trim(), _total);
      setState(() => _mpesaInfo = 'Prompt sent. Ask the customer to enter their PIN.');
      _poll?.cancel();
      var tries = 0;
      _poll = Timer.periodic(const Duration(seconds: 4), (t) async {
        tries++;
        if (_promptTx == null || tries > 45) {
          t.cancel();
          return;
        }
        try {
          final (state, f) = await PosApi.mpesaPromptStatus(Store.i.pin, _promptTx!, _phone.text.trim(), _total);
          if (!mounted) return;
          if (state == 'paid' && f.found) {
            t.cancel();
            setState(() {
              _found = f;
              _mpesaInfo = 'Paid${f.receipt.isEmpty ? '' : ' · ${f.receipt}'}';
            });
          } else if (state == 'cancelled' || state == 'failed') {
            t.cancel();
            setState(() => _mpesaInfo = 'The customer cancelled or the prompt failed. Send again or check payment.');
          }
        } catch (_) {}
      });
    } catch (e) {
      setState(() => _mpesaInfo = '$e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _complete() async {
    setState(() => _saving = true);
    try {
      final amount = _method.cash ? _tendered : _total;
      final sale = await PosApi.sell(
        Store.i.pin,
        uid: _uid,
        lines: [for (final l in widget.lines) {'product_id': l.product.id, 'qty': l.qty}],
        payments: [
          {
            'method_id': _method.id,
            'amount': amount,
            if (_method.mpesa && _found != null) 'mpesa_txn_id': _found!.txnId,
          }
        ],
        customerPhone: _phone.text.trim(),
        customerName: _name.text.trim(),
      );
      if (!mounted) return;
      _poll?.cancel();
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReceiptScreen(sale: sale, setup: widget.setup, autoPrint: true),
      ));
      if (mounted) Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final change = _method.cash ? (_tendered - _total) : 0.0;
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.white, surfaceTintColor: Colors.white, title: Text('Payment', style: h(18))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: C.navy, borderRadius: BorderRadius.circular(18)),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Total to pay', style: TextStyle(color: Color(0xFFC9D3E0))),
                Text(ksh(_total), style: h(30, color: Colors.white)),
              ]),
            ),
            Text('${widget.lines.length} lines', style: const TextStyle(color: Color(0xFFC9D3E0))),
          ]),
        ),
        const SizedBox(height: 14),
        Text('Payment method', style: h(15)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in widget.setup.methods)
            ChoiceChip(
              label: Text(m.name),
              selected: _method.id == m.id,
              onSelected: (_) => setState(() => _method = m),
              selectedColor: C.green,
              showCheckmark: false,
              labelStyle: h(14, w: FontWeight.w700, color: _method.id == m.id ? Colors.white : C.ink),
              backgroundColor: Colors.white,
              side: BorderSide(color: _method.id == m.id ? C.green : C.line),
            ),
        ]),
        const SizedBox(height: 14),
        if (_method.mpesa) _mpesaBox(),
        if (_method.cash) _cashBox(change),
        if (!_method.mpesa && !_method.cash)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: card(),
            child: Text('${_method.name}: ${ksh(_total)} will be recorded.', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: card(),
          child: Column(children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Customer name (optional)', prefixIcon: Icon(Icons.person_outline)),
            ),
            if (!_method.mpesa)
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Customer phone (optional)', prefixIcon: Icon(Icons.phone_outlined)),
              ),
          ]),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 58,
          child: ElevatedButton(
            onPressed: _ready && !_saving ? _complete : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: C.green,
              foregroundColor: Colors.white,
              disabledBackgroundColor: C.line,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: _saving
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : Text('Complete sale', style: h(17, color: _ready ? Colors.white : C.muted)),
          ),
        ),
        const SizedBox(height: 8),
        const Text('Saved as a POS order in the open session, same as the POS screen.',
            textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 12.5)),
      ]),
    );
  }

  Widget _mpesaBox() => Container(
        padding: const EdgeInsets.all(14),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Customer M-Pesa phone', prefixIcon: Icon(Icons.phone_android_rounded)),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _checking ? null : _sendPrompt,
                icon: const Icon(Icons.send_to_mobile_rounded),
                label: const Text('Send prompt'),
                style: OutlinedButton.styleFrom(foregroundColor: C.navy, minimumSize: const Size(0, 48)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _checking ? null : _checkMpesa,
                icon: _checking
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.search_rounded),
                label: const Text('Check payment'),
                style: ElevatedButton.styleFrom(backgroundColor: C.navy, foregroundColor: Colors.white, minimumSize: const Size(0, 48)),
              ),
            ),
          ]),
          if (_mpesaInfo.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _found != null ? C.greenLight : C.bg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Icon(_found != null ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                    color: _found != null ? C.green : C.muted),
                const SizedBox(width: 8),
                Expanded(child: Text(_mpesaInfo, style: const TextStyle(fontWeight: FontWeight.w600))),
              ]),
            ),
          ],
          const SizedBox(height: 8),
          const Text('Customer paid the Till? Enter their number and tap Check payment.',
              style: TextStyle(fontSize: 12.5, color: C.muted)),
        ]),
      );

  Widget _cashBox(double change) {
    final quick = <double>{_total, 50, 100, 200, 500, 1000}.where((v) => v >= _total).toList()..sort();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _cash,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          style: h(22),
          decoration: const InputDecoration(labelText: 'Cash received', prefixText: 'KSh '),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final v in quick)
            ActionChip(
              label: Text(v == _total ? 'Exact' : ksh(v)),
              onPressed: () => setState(() => _cash.text = v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2)),
            ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          const Expanded(child: Text('Change', style: TextStyle(color: C.muted, fontSize: 15))),
          Text(change >= 0 ? ksh(change) : '—', style: h(20, color: change >= 0 ? C.green : C.muted)),
        ]),
      ]),
    );
  }
}
