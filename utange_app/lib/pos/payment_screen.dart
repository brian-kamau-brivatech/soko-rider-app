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

/// Take payment with the POS payment methods, then save the sale as a POS order in the open shift.
class PaymentScreen extends StatefulWidget {
  final PosSetup setup;
  final List<CartLine> lines;
  const PaymentScreen({super.key, required this.setup, required this.lines});
  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  late PayMethod _method = widget.setup.methods.firstWhere((m) => m.cash, orElse: () => widget.setup.methods.first);
  final _cash = TextEditingController();
  final _ref = TextEditingController();
  final _name = TextEditingController();
  final _search = TextEditingController();
  final String _uid = 'ut-${DateTime.now().microsecondsSinceEpoch}';
  bool _saving = false;
  int? _customerId;
  String _customerName = '';
  List<Map<String, dynamic>> _found = const [];
  Timer? _debounce;

  double get _total => double.parse(widget.lines.fold<double>(0, (a, l) => a + l.total).toStringAsFixed(2));
  double get _tendered => double.tryParse(_cash.text.trim()) ?? 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _cash.dispose();
    _ref.dispose();
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  bool get _ready {
    if (_method.cash) return _tendered + 0.001 >= _total;
    if (_method.account) return _customerId != null;
    return true;
  }

  void _searchCustomers(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      if (q.trim().length < 2) {
        if (mounted) setState(() => _found = const []);
        return;
      }
      try {
        final r = await Api.call('/utange/pos/customers', Store.i.base({'q': q.trim()}));
        if (mounted) setState(() => _found = ll(r['customers']));
      } catch (_) {}
    });
  }

  Future<void> _complete() async {
    setState(() => _saving = true);
    try {
      final amount = _method.cash ? _tendered : _total;
      final r = await Api.call('/utange/pos/sell', Store.i.base({
        'uid': _uid,
        'lines': [for (final l in widget.lines) {'product_id': l.product.id, 'qty': l.qty}],
        'payments': [
          {'method_id': _method.id, 'amount': amount, if (_ref.text.trim().isNotEmpty) 'ref': _ref.text.trim()}
        ],
        if (_customerId != null) 'customer_id': _customerId,
        if (_customerId == null && _name.text.trim().isNotEmpty) 'customer_name': _name.text.trim(),
      }));
      final sale = Sale.fromJson(Map<String, dynamic>.from(r['order'] as Map));
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReceiptScreen(sale: sale, setup: widget.setup, autoPrint: true),
      ));
      if (mounted) Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
      await Store.i.handle(e);
      if (e.cashier && mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final change = _method.cash ? (_tendered - _total) : 0.0;
    return Scaffold(
      appBar: bar('Payment'),
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
        if (_method.cash) _cashBox(change),
        if (_method.account) _accountBox(),
        if (!_method.cash && !_method.account)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: card(),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${_method.name}: ${ksh(_total)}', style: const TextStyle(fontWeight: FontWeight.w700)),
              TextField(
                controller: _ref,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                    labelText: _method.mpesa ? 'M-Pesa code (optional)' : 'Reference (optional)',
                    prefixIcon: const Icon(Icons.tag_rounded)),
              ),
            ]),
          ),
        if (!_method.account) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: card(),
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Customer / room (optional)', prefixIcon: Icon(Icons.person_outline)),
            ),
          ),
        ],
        const SizedBox(height: 18),
        primaryButton('Complete sale', _ready ? _complete : null, icon: Icons.check_circle_rounded, busy: _saving),
        const SizedBox(height: 8),
        const Text('Saved as a POS order in the open shift, same as the Odoo POS screen.',
            textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 12.5)),
      ]),
    );
  }

  Widget _accountBox() => Container(
        padding: const EdgeInsets.all(14),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_customerId != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.check_circle_rounded, color: C.green),
              title: Text(_customerName, style: h(15, w: FontWeight.w700)),
              subtitle: const Text('Charged to this customer account'),
              trailing: TextButton(onPressed: () => setState(() => _customerId = null), child: const Text('Change')),
            )
          else ...[
            TextField(
              controller: _search,
              onChanged: _searchCustomers,
              decoration: const InputDecoration(labelText: 'Find customer (name, phone, room)', prefixIcon: Icon(Icons.search_rounded)),
            ),
            for (final c in _found)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_rounded, color: C.navy),
                title: Text(ss(c['name'])),
                subtitle: ss(c['phone']).isEmpty ? null : Text(ss(c['phone'])),
                onTap: () => setState(() {
                  _customerId = ii(c['id']);
                  _customerName = ss(c['name']);
                }),
              ),
            const SizedBox(height: 6),
            const Text('A Customer Account sale needs the customer (the bill goes to their account).',
                style: TextStyle(fontSize: 12.5, color: C.muted)),
          ],
        ]),
      );

  Widget _cashBox(double change) {
    final quick = <double>{_total, 100, 200, 500, 1000, 2000, 5000}.where((v) => v >= _total).toList()..sort();
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
          for (final v in quick.take(5))
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
