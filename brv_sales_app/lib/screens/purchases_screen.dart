import 'package:flutter/material.dart';
import '../bus.dart';
import '../db.dart';
import '../fmt.dart';
import '../ops.dart';
import '../perms.dart';
import '../sales.dart' show SaleError;
import '../session.dart';
import '../ui.dart';
import 'stock_screen.dart' show locations, pickLine;

class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({super.key});
  @override
  State<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends State<PurchasesScreen> {
  List<Map<String, Object?>> _rows = [];
  String _state = 'draft';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.q(
        'SELECT p.*, s.name AS supplier, l.name AS location, (SELECT COALESCE(SUM(amount),0) FROM supplier_payments sp WHERE sp.purchase_id = p.id) AS paid '
        'FROM purchases p LEFT JOIN suppliers s ON s.id = p.supplier_id LEFT JOIN locations l ON l.id = p.location_id '
        'WHERE p.state = ? ORDER BY p.id DESC LIMIT 200',
        [_state]);
    if (mounted) setState(() => _rows = r);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Purchases')),
        floatingActionButton: Session.i.can(P.purchase)
            ? FloatingActionButton.extended(
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PurchaseForm()));
                  _load();
                },
                icon: const Icon(Icons.add),
                label: const Text('Purchase'),
              )
            : null,
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: PeriodSwitch(
                value: _state,
                options: const [('draft', 'To receive'), ('received', 'Received'), ('cancel', 'Cancelled')],
                onChanged: (v) { setState(() => _state = v); _load(); },
              ),
            ),
          ),
          Expanded(
            child: _rows.isEmpty
                ? const Empty(Icons.local_shipping_outlined, 'Nothing here.')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                    itemCount: _rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, k) {
                      final p = _rows[k];
                      final due = d(p['total']) - d(p['paid']);
                      return Container(
                        decoration: box(),
                        child: ListTile(
                          title: Text('${s(p['number'])} · ${s(p['supplier'])}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text('${dateText(p['date'])} · into ${s(p['location'])}'),
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(money(d(p['total'])), style: h(14)),
                            if (s(p['state']) == 'received')
                              Text(due > 0.004 ? 'Owing ${money(due, symbol: false)}' : 'Paid', style: TextStyle(color: due > 0.004 ? C.amber : C.green, fontSize: 12, fontWeight: FontWeight.w700)),
                          ]),
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PurchaseDetail(id: n(p['id']))));
                            _load();
                          },
                        ),
                      );
                    },
                  ),
          ),
        ]),
      );
}

class PurchaseForm extends StatefulWidget {
  final int? id;
  const PurchaseForm({super.key, this.id});
  @override
  State<PurchaseForm> createState() => _PurchaseFormState();
}

class _PurchaseFormState extends State<PurchaseForm> {
  List<Map<String, Object?>> _sups = [];
  List<Map<String, Object?>> _locs = [];
  int? _sup;
  int _loc = 0;
  final List<(int, String, double, double)> _lines = [];
  final _note = TextEditingController();
  final _ref = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sp = await Db.q('SELECT * FROM suppliers WHERE active = 1 ORDER BY name');
    final l = await locations();
    if (widget.id != null) {
      final p = await Db.one('SELECT * FROM purchases WHERE id = ?', [widget.id]);
      for (final x in await Db.q('SELECT * FROM purchase_lines WHERE purchase_id = ?', [widget.id])) {
        _lines.add((n(x['product_id']), s(x['name']), d(x['qty']), d(x['cost'])));
      }
      _sup = n(p?['supplier_id']);
      _loc = n(p?['location_id']);
      _note.text = s(p?['note']);
      _ref.text = s(p?['supplier_ref']);
    }
    if (!mounted) return;
    setState(() {
      _sups = sp;
      _locs = l;
      if (_loc == 0) _loc = l.isEmpty ? 0 : n(l.first['id']);
    });
  }

  Future<void> _newSupplier() async {
    final name = await ask(context, 'New supplier', label: 'Name');
    if (name == null || name.trim().isEmpty) return;
    final db = await Db.get();
    final id = await db.insert('suppliers', {'name': name.trim(), 'created_at': nowIso()});
    await _reloadSuppliers();
    setState(() => _sup = id);
  }

  Future<void> _reloadSuppliers() async {
    final sp = await Db.q('SELECT * FROM suppliers WHERE active = 1 ORDER BY name');
    if (mounted) setState(() => _sups = sp);
  }

  Future<void> _add() async {
    final r = await pickLine(context, withCost: true, locationId: _loc);
    if (r != null) setState(() => _lines.add((n(r.$1['id']), s(r.$1['name']), r.$2, r.$3)));
  }

  Future<void> _save({bool receive = false}) async {
    if (_sup == null) {
      toast(context, 'Choose the supplier.');
      return;
    }
    try {
      final id = await Purchases.save(id: widget.id, supplierId: _sup!, locationId: _loc, lines: _lines, note: _note.text.trim(), supplierRef: _ref.text.trim());
      if (receive) await Purchases.receive(id);
      changed();
      if (mounted) {
        toast(context, receive ? 'Received: stock added.' : 'Saved. Receive it when the goods arrive.');
        Navigator.pop(context);
      }
    } on SaleError catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _lines.fold<double>(0, (a, l) => a + l.$3 * l.$4);
    return Scaffold(
      appBar: AppBar(title: Text(widget.id == null ? 'New purchase' : 'Edit purchase')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              value: _sups.any((x) => n(x['id']) == _sup) ? _sup : null,
              decoration: const InputDecoration(labelText: 'Supplier'),
              items: [for (final x in _sups) DropdownMenuItem(value: n(x['id']), child: Text(s(x['name'])))],
              onChanged: (v) => setState(() => _sup = v),
            ),
          ),
          IconButton(onPressed: _newSupplier, icon: const Icon(Icons.person_add_alt)),
        ]),
        const SizedBox(height: 10),
        DropdownButtonFormField<int>(
          value: _locs.any((x) => n(x['id']) == _loc) ? _loc : null,
          decoration: const InputDecoration(labelText: 'Receive into'),
          items: [for (final x in _locs) DropdownMenuItem(value: n(x['id']), child: Text(s(x['name'])))],
          onChanged: (v) => setState(() => _loc = v ?? _loc),
        ),
        const SizedBox(height: 10),
        TextField(controller: _ref, decoration: const InputDecoration(labelText: 'Supplier invoice / delivery no.')),
        const Label('Items'),
        Container(
          decoration: box(),
          child: Column(children: [
            for (final l in _lines)
              ListTile(
                title: Text(l.$2),
                subtitle: Text('${qty(l.$3)} x ${money(l.$4, symbol: false)}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(money(l.$3 * l.$4, symbol: false), style: h(14)),
                  IconButton(onPressed: () => setState(() => _lines.remove(l)), icon: const Icon(Icons.close)),
                ]),
              ),
            ListTile(leading: const Icon(Icons.add), title: const Text('Add item'), onTap: _add),
            KV('Total', money(total), bold: true),
          ]),
        ),
        const SizedBox(height: 10),
        TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note')),
        const SizedBox(height: 16),
        OutlinedButton(onPressed: _lines.isEmpty ? null : () => _save(), child: const Text('Save order (receive later)')),
        if (Session.i.can(P.purchaseReceive)) ...[
          const SizedBox(height: 10),
          FilledButton(onPressed: _lines.isEmpty ? null : () => _save(receive: true), child: const Text('Save and receive now')),
        ],
      ]),
    );
  }
}

class PurchaseDetail extends StatefulWidget {
  final int id;
  const PurchaseDetail({super.key, required this.id});
  @override
  State<PurchaseDetail> createState() => _PurchaseDetailState();
}

class _PurchaseDetailState extends State<PurchaseDetail> {
  Map<String, Object?>? _p;
  List<Map<String, Object?>> _lines = [];
  double _paid = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await Db.one(
        'SELECT p.*, s.name AS supplier, l.name AS location, u.name AS user FROM purchases p LEFT JOIN suppliers s ON s.id = p.supplier_id '
        'LEFT JOIN locations l ON l.id = p.location_id LEFT JOIN users u ON u.id = p.user_id WHERE p.id = ?',
        [widget.id]);
    final l = await Db.q('SELECT * FROM purchase_lines WHERE purchase_id = ?', [widget.id]);
    final paid = await Purchases.paidOn(widget.id);
    if (mounted) setState(() { _p = p; _lines = l; _paid = paid; });
  }

  Future<void> _pay() async {
    final p = _p!;
    final due = r2(d(p['total']) - _paid);
    final r = await payDialog(context, 'Pay ${p['supplier']}', due);
    if (r == null) return;
    try {
      await Purchases.pay(supplierId: n(p['supplier_id']), purchaseId: widget.id, methodId: r.$1, amount: r.$2, ref: r.$3.isEmpty ? s(p['number']) : r.$3);
      changed();
      if (mounted) toast(context, 'Payment saved.');
      _load();
    } on SaleError catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final draft = p != null && s(p['state']) == 'draft';
    final due = p == null ? 0.0 : r2(d(p['total']) - _paid);
    return Scaffold(
      appBar: AppBar(title: Text(p == null ? 'Purchase' : s(p['number']))),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Container(
                decoration: box(),
                child: Column(children: [
                  KV('Supplier', s(p['supplier'])),
                  KV('Into', s(p['location'])),
                  KV('Status', draft ? 'To receive' : s(p['state'])),
                  if (s(p['supplier_ref']).isNotEmpty) KV('Supplier ref.', s(p['supplier_ref'])),
                  KV('Made by', '${s(p['user'])} · ${dateText(p['date'])}'),
                  if (s(p['received_at']).isNotEmpty) KV('Received', dateText(p['received_at'])),
                ]),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: box(),
                child: Column(children: [
                  for (final l in _lines)
                    ListTile(
                      title: Text(s(l['name'])),
                      subtitle: Text('${qty(d(l['qty']))} x ${money(d(l['cost']), symbol: false)}'),
                      trailing: Text(money(d(l['total']), symbol: false), style: h(14)),
                    ),
                  KV('Total', money(d(p['total'])), bold: true),
                  if (s(p['state']) == 'received') ...[
                    KV('Paid', money(_paid)),
                    KV('Owing', money(due), bold: true, color: due > 0.004 ? C.amber : C.green),
                  ],
                ]),
              ),
              const SizedBox(height: 16),
              if (draft && Session.i.can(P.purchaseReceive))
                FilledButton.icon(
                  onPressed: () async {
                    try {
                      await Purchases.receive(widget.id);
                      changed();
                      if (context.mounted) toast(context, 'Received: stock added.');
                      _load();
                    } on SaleError catch (e) {
                      if (context.mounted) toast(context, e.message);
                    }
                  },
                  icon: const Icon(Icons.download_done),
                  label: const Text('Receive goods (add to stock)'),
                ),
              if (draft && Session.i.can(P.purchase)) ...[
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PurchaseForm(id: widget.id)));
                    _load();
                  },
                  child: const Text('Edit'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () async {
                    if (!await confirm(context, 'Cancel this order?', 'It will not be received.', ok: 'Cancel order', danger: true)) return;
                    await Purchases.cancel(widget.id);
                    _load();
                  },
                  style: OutlinedButton.styleFrom(foregroundColor: C.red),
                  child: const Text('Cancel order'),
                ),
              ],
              if (s(p['state']) == 'received' && due > 0.004 && Session.i.can(P.supplierPay))
                FilledButton.icon(onPressed: _pay, icon: const Icon(Icons.payments_outlined), label: Text('Pay ${money(due)}')),
            ]),
    );
  }
}

/// How much and how (cash, M-Pesa, bank). Returns (method id, amount, reference).
Future<(int, double, String)?> payDialog(BuildContext context, String title, double suggested) async {
  final methods = await Db.q("SELECT * FROM pay_methods WHERE active = 1 AND kind != 'credit' ORDER BY id");
  if (!context.mounted || methods.isEmpty) return null;
  int method = n(methods.first['id']);
  final amount = TextEditingController(text: suggested > 0 ? suggested.toStringAsFixed(2) : '');
  final ref = TextEditingController();
  return showDialog<(int, double, String)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<int>(
            value: method,
            decoration: const InputDecoration(labelText: 'Paid by'),
            items: [for (final m in methods) DropdownMenuItem(value: n(m['id']), child: Text(s(m['name'])))],
            onChanged: (v) => set(() => method = v ?? method),
          ),
          const SizedBox(height: 10),
          TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount', prefixText: 'KSh ')),
          const SizedBox(height: 10),
          TextField(controller: ref, decoration: const InputDecoration(labelText: 'Reference (M-Pesa code, cheque...)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final a = numIn(amount.text);
              if (a == null || a <= 0) return;
              Navigator.pop(ctx, (method, a, ref.text.trim()));
            },
            style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

class SuppliersScreen extends StatefulWidget {
  const SuppliersScreen({super.key});
  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.q(
        "SELECT s.*, (SELECT COALESCE(SUM(total),0) FROM purchases p WHERE p.supplier_id = s.id AND p.state = 'received') - "
        "(SELECT COALESCE(SUM(amount),0) FROM supplier_payments sp WHERE sp.supplier_id = s.id) AS owing FROM suppliers s ORDER BY s.active DESC, s.name");
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _edit([Map<String, Object?>? x]) async {
    final name = TextEditingController(text: s(x?['name']));
    final phone = TextEditingController(text: s(x?['phone']));
    final email = TextEditingController(text: s(x?['email']));
    final pin = TextEditingController(text: s(x?['tax_pin']));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(x == null ? 'New supplier' : 'Edit supplier'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
            const SizedBox(height: 8),
            TextField(controller: email, decoration: const InputDecoration(labelText: 'Email')),
            const SizedBox(height: 8),
            TextField(controller: pin, decoration: const InputDecoration(labelText: 'KRA PIN')),
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
    final vals = {'name': name.text.trim(), 'phone': phone.text.trim(), 'email': email.text.trim(), 'tax_pin': pin.text.trim()};
    if (x == null) {
      await db.insert('suppliers', {...vals, 'created_at': nowIso()});
    } else {
      await db.update('suppliers', vals, where: 'id = ?', whereArgs: [x['id']]);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Suppliers')),
        floatingActionButton: FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add)),
        body: _rows.isEmpty
            ? const Empty(Icons.storefront_outlined, 'No suppliers yet.')
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
                itemCount: _rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, k) {
                  final x = _rows[k];
                  final owing = d(x['owing']);
                  return Container(
                    decoration: box(),
                    child: ListTile(
                      leading: Avatar(s(x['name']), size: 40),
                      title: Text(s(x['name']), style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(s(x['phone'])),
                      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text(owing > 0.004 ? money(owing) : 'Nothing owed', style: h(13.5, color: owing > 0.004 ? C.amber : C.green)),
                        if (owing > 0.004 && Session.i.can(P.supplierPay))
                          GestureDetector(
                            onTap: () async {
                              final r = await payDialog(context, 'Pay ${x['name']}', owing);
                              if (r == null) return;
                              try {
                                await Purchases.pay(supplierId: n(x['id']), methodId: r.$1, amount: r.$2, ref: r.$3);
                                changed();
                                _load();
                              } on SaleError catch (e) {
                                if (context.mounted) toast(context, e.message);
                              }
                            },
                            child: const Text('Pay', style: TextStyle(color: C.ink, fontWeight: FontWeight.w800, decoration: TextDecoration.underline)),
                          ),
                      ]),
                      onTap: () => _edit(x),
                    ),
                  );
                },
              ),
      );
}
