import 'package:flutter/material.dart';
import '../bus.dart';
import '../db.dart';
import '../fmt.dart';
import '../ops.dart';
import '../perms.dart';
import '../sales.dart' show SaleError;
import '../session.dart';
import '../ui.dart';
import 'purchases_screen.dart' show payDialog;
import 'sales_screen.dart';

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});
  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
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
    final r = await Db.q(
        "SELECT c.*, (SELECT COALESCE(SUM(sp.amount),0) FROM sale_payments sp JOIN sales s ON s.id = sp.sale_id JOIN pay_methods m ON m.id = sp.method_id "
        "WHERE m.kind = 'credit' AND s.customer_id = c.id) - (SELECT COALESCE(SUM(amount),0) FROM customer_payments cp WHERE cp.customer_id = c.id) AS owes "
        "FROM customers c ORDER BY c.active DESC, c.name");
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _edit([Map<String, Object?>? x]) async {
    final name = TextEditingController(text: s(x?['name']));
    final phone = TextEditingController(text: s(x?['phone']));
    final email = TextEditingController(text: s(x?['email']));
    final pin = TextEditingController(text: s(x?['tax_pin']));
    final limit = TextEditingController(text: x == null ? '0' : qty(d(x['credit_limit'])));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(x == null ? 'New customer' : 'Edit customer'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
            const SizedBox(height: 8),
            TextField(controller: email, decoration: const InputDecoration(labelText: 'Email')),
            const SizedBox(height: 8),
            TextField(controller: pin, decoration: const InputDecoration(labelText: 'KRA PIN')),
            const SizedBox(height: 8),
            TextField(controller: limit, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Credit limit (0 = no limit)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(minimumSize: const Size(0, 42)), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    final db = await Db.get();
    final vals = {
      'name': name.text.trim(), 'phone': phone.text.trim(), 'email': email.text.trim(), 'tax_pin': pin.text.trim(),
      'credit_limit': numIn(limit.text) ?? 0,
    };
    if (x == null) {
      await Db.ins(db, 'customers', {...vals, 'created_at': nowIso()});
    } else {
      await db.update('customers', vals, where: 'id = ?', whereArgs: [x['id']]);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = _rows.where((c) => q.isEmpty || s(c['name']).toLowerCase().contains(q) || s(c['phone']).contains(q)).toList();
    final owed = _rows.fold<double>(0, (a, c) => a + (d(c['owes']) > 0 ? d(c['owes']) : 0));
    return Scaffold(
      appBar: AppBar(title: const Text('Customers')),
      floatingActionButton: Session.i.can(P.customers) ? FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add)) : null,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(decoration: const InputDecoration(hintText: 'Search name or phone', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => _q = v)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Row(children: [Text('${shown.length} customers', style: muted), const Spacer(), Text('Owed to you ${money(owed)}', style: h(14))]),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Empty(Icons.people_outline, 'No customers.')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, k) {
                    final c = shown[k];
                    final owes = d(c['owes']);
                    return Container(
                      decoration: box(),
                      child: ListTile(
                        leading: Avatar(s(c['name']), size: 40),
                        title: Text(s(c['name']), style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(s(c['phone'])),
                        trailing: Text(owes > 0.004 ? money(owes) : '-', style: h(13.5, color: owes > 0.004 ? C.amber : C.muted)),
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CustomerDetail(id: n(c['id']))));
                          _load();
                        },
                        onLongPress: Session.i.can(P.customers) ? () => _edit(c) : null,
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

class CustomerDetail extends StatefulWidget {
  final int id;
  const CustomerDetail({super.key, required this.id});
  @override
  State<CustomerDetail> createState() => _CustomerDetailState();
}

class _CustomerDetailState extends State<CustomerDetail> {
  Map<String, Object?>? _c;
  List<Map<String, Object?>> _items = [];
  double _owes = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await Db.one('SELECT * FROM customers WHERE id = ?', [widget.id]);
    final sales = await Db.q(
        "SELECT s.id, s.number AS ref, s.date, sp.amount AS amt, 'sale' AS t FROM sale_payments sp JOIN sales s ON s.id = sp.sale_id "
        "JOIN pay_methods m ON m.id = sp.method_id WHERE m.kind = 'credit' AND s.customer_id = ?",
        [widget.id]);
    final pays = await Db.q(
        "SELECT cp.id, CASE WHEN cp.ref = '' THEN m.name ELSE cp.ref END AS ref, cp.date, -cp.amount AS amt, 'pay' AS t FROM customer_payments cp "
        "JOIN pay_methods m ON m.id = cp.method_id WHERE cp.customer_id = ?",
        [widget.id]);
    final all = [...sales, ...pays]..sort((a, b) => s(b['date']).compareTo(s(a['date'])));
    final owes = all.fold<double>(0, (a, x) => a + d(x['amt']));
    if (mounted) setState(() { _c = c; _items = all; _owes = owes; });
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(title: Text(c == null ? 'Customer' : s(c['name']))),
      body: c == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: box(color: C.ink, border: false),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Owes you', style: TextStyle(color: Color(0xFFCBD5E1))),
                  Text(money(_owes), style: h(30, color: Colors.white)),
                  if (d(c['credit_limit']) > 0) Text('Credit limit ${money(d(c['credit_limit']))}', style: const TextStyle(color: Color(0xFFCBD5E1))),
                  if (s(c['phone']).isNotEmpty) Text(s(c['phone']), style: const TextStyle(color: Color(0xFFCBD5E1))),
                ]),
              ),
              const SizedBox(height: 12),
              if (Session.i.can(P.customerPay) && _owes > 0.004)
                FilledButton.icon(
                  onPressed: () async {
                    final r = await payDialog(context, 'Payment from ${c['name']}', _owes);
                    if (r == null) return;
                    try {
                      await Customers.receive(customerId: widget.id, methodId: r.$1, amount: r.$2, ref: r.$3);
                      changed();
                      if (context.mounted) toast(context, 'Payment received.');
                      _load();
                    } on SaleError catch (e) {
                      if (context.mounted) toast(context, e.message);
                    }
                  },
                  icon: const Icon(Icons.payments_outlined),
                  label: const Text('Receive payment'),
                ),
              const Label('Statement'),
              Container(
                decoration: box(),
                child: Column(children: [
                  if (_items.isEmpty) const Empty(Icons.receipt_long_outlined, 'No credit sales.'),
                  for (final x in _items)
                    ListTile(
                      title: Text(s(x['t']) == 'sale' ? 'Credit sale ${s(x['ref'])}' : 'Paid (${s(x['ref'])})'),
                      subtitle: Text(dateText(x['date'])),
                      trailing: Text(money(d(x['amt'])), style: h(14, color: d(x['amt']) < 0 ? C.green : C.text)),
                      onTap: s(x['t']) == 'sale' ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SaleDetail(saleId: n(x['id'])))) : null,
                    ),
                ]),
              ),
            ]),
    );
  }
}
