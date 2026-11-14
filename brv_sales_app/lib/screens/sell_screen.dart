import 'package:flutter/material.dart';
import '../bus.dart';
import '../db.dart';
import '../fmt.dart';
import '../perms.dart';
import '../receipt.dart';
import '../sales.dart';
import '../session.dart';
import '../settings.dart';
import '../ui.dart';
import 'sales_screen.dart';
import 'shell.dart';
import 'shift_screen.dart';

class SellScreen extends StatefulWidget {
  const SellScreen({super.key});
  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  List<Map<String, Object?>> _products = [];
  List<Map<String, Object?>> _cats = [];
  int _cat = 0;
  String _q = '';
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    dataVersion.addListener(_load);
    Session.i.addListener(_load);
    Cart.i.addListener(_redraw);
    _load();
  }

  @override
  void dispose() {
    dataVersion.removeListener(_load);
    Session.i.removeListener(_load);
    Cart.i.removeListener(_redraw);
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (!Session.i.signedIn) return;
    final loc = await Sales.sellingLocation();
    final p = await Db.q(
        'SELECT p.*, (SELECT COALESCE(SUM(qty),0) FROM stock s WHERE s.product_id = p.id AND s.location_id = ?) AS on_hand '
        'FROM products p WHERE p.active = 1 ORDER BY p.name',
        [loc]);
    final c = await Db.q('SELECT * FROM categories ORDER BY name');
    if (mounted) {
      setState(() {
        _products = p;
        _cats = c;
      });
    }
  }

  void _add(Map<String, Object?> p) {
    final tracked = n(p['track']) == 1;
    if (tracked && Settings.i.blockNoStock && !Session.i.can(P.sellNoStock)) {
      final left = d(p['on_hand']) - Cart.i.qtyOf(n(p['id']));
      if (left < 1 - 0.00001) {
        toast(context, '${p['name']}: no stock left here. Make a requisition from the store.');
        return;
      }
    }
    Cart.i.add(p);
  }

  void _scan(String code) {
    final c = code.trim();
    if (c.isEmpty) return;
    final hit = _products.where((p) => s(p['barcode']) == c || s(p['sku']).toLowerCase() == c.toLowerCase()).toList();
    if (hit.length == 1) {
      _add(hit.first);
      _search.clear();
      setState(() => _q = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ses = Session.i;
    final needShift = Settings.i.requireShift && ses.shift == null;
    final q = _q.trim().toLowerCase();
    final shown = _products.where((p) {
      if (_cat > 0 && n(p['category_id']) != _cat) return false;
      if (q.isEmpty) return true;
      return s(p['name']).toLowerCase().contains(q) || s(p['sku']).toLowerCase().contains(q) || s(p['barcode']) == q;
    }).toList();
    final cart = Cart.i;
    return Scaffold(
      appBar: TopBar('Sell', actions: [
        IconButton(
          tooltip: 'Sales',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SalesScreen())),
          icon: const Icon(Icons.receipt_long_outlined),
        ),
      ]),
      body: Column(children: [
        if (needShift)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            padding: const EdgeInsets.all(14),
            decoration: box(color: C.amberLight, border: false),
            child: Row(children: [
              const Icon(Icons.lock_outline, color: C.amber),
              const SizedBox(width: 10),
              const Expanded(child: Text('Open your shift (cash drawer) to sell.', style: TextStyle(fontWeight: FontWeight.w700))),
              if (ses.can(P.shift))
                FilledButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShiftScreen())),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                  child: const Text('Open'),
                ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              hintText: 'Search or scan barcode',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _q.isEmpty ? null : IconButton(onPressed: () => setState(() { _search.clear(); _q = ''; }), icon: const Icon(Icons.close)),
            ),
            onChanged: (v) => setState(() => _q = v),
            onSubmitted: _scan,
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            _chip('All', 0),
            for (final c in _cats) _chip(s(c['name']), n(c['id'])),
          ]),
        ),
        Expanded(
          child: shown.isEmpty
              ? Empty(Icons.inventory_2_outlined, _products.isEmpty ? 'No products yet. Add them under Stock > Products.' : 'Nothing found.')
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 190, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.05),
                  itemCount: shown.length,
                  itemBuilder: (_, k) => _tile(shown[k]),
                ),
        ),
        if (!cart.isEmpty)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CartScreen())),
                style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 56)),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(color: C.gold, borderRadius: BorderRadius.circular(8)),
                    child: Text(qty(cart.count), style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 12),
                  const Text('View sale'),
                  const Spacer(),
                  Text(money(cart.total), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _chip(String label, int id) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ChoiceChip(
          label: Text(label),
          selected: _cat == id,
          onSelected: (_) => setState(() => _cat = id),
          selectedColor: C.ink,
          labelStyle: TextStyle(color: _cat == id ? Colors.white : C.text, fontWeight: FontWeight.w700),
          showCheckmark: false,
        ),
      );

  Widget _tile(Map<String, Object?> p) {
    final inCart = Cart.i.qtyOf(n(p['id']));
    final tracked = n(p['track']) == 1;
    final left = d(p['on_hand']) - inCart;
    final out = tracked && left <= 0;
    return Material(
      color: inCart > 0 ? C.ink : Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _add(p),
        onLongPress: () async {
          final v = numIn(await ask(context, 'Quantity of ${p['name']}', number: true, initial: '1'));
          if (v != null && v > 0) Cart.i.add(p, q: v);
        },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: inCart > 0 ? C.ink : C.line)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Avatar(s(p['name']), size: 34, bg: inCart > 0 ? const Color(0xFF233B63) : C.soft, fg: inCart > 0 ? Colors.white : C.ink),
              const Spacer(),
              if (inCart > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: C.gold, borderRadius: BorderRadius.circular(8)),
                  child: Text(qty(inCart), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                ),
            ]),
            const Spacer(),
            Text(s(p['name']), maxLines: 2, overflow: TextOverflow.ellipsis,
                style: h(14, color: inCart > 0 ? Colors.white : C.text, w: FontWeight.w700)),
            const SizedBox(height: 2),
            Row(children: [
              Expanded(child: Text(money(d(p['price']), symbol: false), style: h(14, color: inCart > 0 ? C.gold : C.ink))),
              if (tracked)
                Text(out ? 'Out' : qty(left), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: out ? C.red : (inCart > 0 ? const Color(0xFFCBD5E1) : C.muted))),
            ]),
          ]),
        ),
      ),
    );
  }
}

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});
  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  @override
  void initState() {
    super.initState();
    Cart.i.addListener(_redraw);
  }

  @override
  void dispose() {
    Cart.i.removeListener(_redraw);
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  Future<void> _edit(CartLine l) async {
    final ses = Session.i;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(l.name, style: h(17))),
          ListTile(leading: const Icon(Icons.numbers), title: const Text('Quantity'), onTap: () => Navigator.pop(ctx, 'qty')),
          if (ses.can(P.discount)) ListTile(leading: const Icon(Icons.percent), title: const Text('Discount'), onTap: () => Navigator.pop(ctx, 'disc')),
          if (ses.can(P.priceChange)) ListTile(leading: const Icon(Icons.sell_outlined), title: const Text('Change price'), onTap: () => Navigator.pop(ctx, 'price')),
          ListTile(leading: const Icon(Icons.delete_outline, color: C.red), title: const Text('Remove'), onTap: () => Navigator.pop(ctx, 'del')),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'qty': {
        final v = numIn(await ask(context, 'Quantity', number: true, initial: qty(l.qty)));
        if (v != null) Cart.i.setQty(l, v);
      }
      case 'disc': {
        final v = await ask(context, 'Discount on ${l.name}', label: 'Amount (e.g. 50) or percent (e.g. 10%)', initial: l.discount > 0 ? money(l.discount, symbol: false) : '');
        if (v == null) return;
        final t = v.trim();
        final amt = t.endsWith('%') ? r2(l.gross * (numIn(t.substring(0, t.length - 1)) ?? 0) / 100) : (numIn(t) ?? 0);
        if (amt < 0 || amt > l.gross) {
          if (mounted) toast(context, 'The discount must be between 0 and ${money(l.gross)}.');
          return;
        }
        l.discount = amt;
        Cart.i.changed();
      }
      case 'price': {
        final v = numIn(await ask(context, 'Price of ${l.name}', number: true, initial: money(l.price, symbol: false)));
        if (v != null && v >= 0) {
          l.price = v;
          Cart.i.changed();
        }
      }
      case 'del': {
        Cart.i.setQty(l, 0);
      }
    }
  }

  Future<void> _customer() async {
    final list = await Db.q('SELECT * FROM customers WHERE active = 1 ORDER BY name');
    if (!mounted) return;
    final c = await pickFrom(context, 'Customer', [{'id': 0, 'name': 'Walk-in customer (none)'}, ...list],
        sub: (m) => s(m['phone']));
    if (c == null) return;
    Cart.i.customerId = n(c['id']) == 0 ? null : n(c['id']);
    Cart.i.customerName = n(c['id']) == 0 ? '' : s(c['name']);
    Cart.i.changed();
  }

  @override
  Widget build(BuildContext context) {
    final cart = Cart.i;
    return Scaffold(
      appBar: AppBar(title: const Text('Sale'), actions: [
        if (!cart.isEmpty)
          IconButton(
            tooltip: 'Clear',
            onPressed: () async {
              if (await confirm(context, 'Clear the sale?', 'All items will be removed.', ok: 'Clear', danger: true)) {
                Cart.i.clear();
                if (context.mounted) Navigator.pop(context);
              }
            },
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
      ]),
      body: cart.isEmpty
          ? const Empty(Icons.shopping_basket_outlined, 'The sale is empty.')
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
              Container(
                decoration: box(),
                child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(cart.customerName.isEmpty ? 'Walk-in customer' : cart.customerName),
                  subtitle: const Text('Tap to choose a customer (needed for credit)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _customer,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: box(),
                child: Column(children: [
                  for (final l in cart.lines) ...[
                    ListTile(
                      onTap: () => _edit(l),
                      title: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${money(l.price, symbol: false)} each${l.discount > 0 ? ' · discount ${money(l.discount, symbol: false)}' : ''}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(onPressed: () => Cart.i.setQty(l, l.qty - 1), icon: const Icon(Icons.remove_circle_outline)),
                        Text(qty(l.qty), style: h(16)),
                        IconButton(onPressed: () => Cart.i.setQty(l, l.qty + 1), icon: const Icon(Icons.add_circle_outline)),
                        SizedBox(width: 78, child: Text(money(l.total, symbol: false), textAlign: TextAlign.right, style: h(14))),
                      ]),
                    ),
                    const Divider(),
                  ],
                  if (cart.discount > 0) KV('Discount', '-${money(cart.discount)}'),
                  if (cart.tax > 0) KV('VAT included', money(cart.tax)),
                  KV('Total', money(cart.total), bold: true),
                ]),
              ),
            ]),
      bottomNavigationBar: cart.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: FilledButton(
                  onPressed: () async {
                    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const PayScreen()));
                    if (done == true && context.mounted) Navigator.pop(context);
                  },
                  style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 56)),
                  child: Text('Charge ${money(cart.total)}'),
                ),
              ),
            ),
    );
  }
}

class PayScreen extends StatefulWidget {
  const PayScreen({super.key});
  @override
  State<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends State<PayScreen> {
  List<Map<String, Object?>> _methods = [];
  final List<Pay> _pays = [];
  bool _busy = false;

  double get _total => Cart.i.total;
  double get _paid => _pays.fold<double>(0, (a, p) => a + p.amount);
  double get _left => r2(_total - _paid);

  @override
  void initState() {
    super.initState();
    Db.q('SELECT * FROM pay_methods WHERE active = 1 ORDER BY id').then((m) {
      if (mounted) setState(() => _methods = m);
    });
  }

  Future<void> _addPay(Map<String, Object?> m) async {
    final kind = s(m['kind']);
    if (kind == 'credit' && Cart.i.customerId == null) {
      toast(context, 'Choose the customer first (back to the sale, tap the customer).');
      return;
    }
    final def = _left > 0 ? _left : 0.0;
    final v = await ask(context, s(m['name']),
        label: kind == 'cash' ? 'Cash received' : 'Amount', number: true, initial: money(def, symbol: false).replaceAll(',', ''));
    final amt = numIn(v);
    if (amt == null || amt <= 0) return;
    var ref = '';
    if (kind == 'mpesa' || kind == 'card') {
      ref = (await ask(context, kind == 'mpesa' ? 'M-Pesa code (optional)' : 'Card reference (optional)')) ?? '';
    }
    setState(() => _pays.add(Pay(n(m['id']), kind, s(m['name']), amt, ref: ref.trim().toUpperCase())));
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    try {
      final change = r2(_paid - _total);
      final id = await Sales.checkout(Cart.i, _pays);
      Cart.i.clear();
      changed();
      if (!mounted) return;
      if (Settings.i.printAfterSale) {
        await printSale(id);
      }
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.popUntil((r) => r.isFirst);
      await nav.push(MaterialPageRoute(builder: (_) => DoneScreen(saleId: id, change: change)));
    } on SaleError catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final left = _left;
    return Scaffold(
      appBar: AppBar(title: const Text('Payment')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: box(color: C.ink, border: false),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('To pay', style: TextStyle(color: Color(0xFFCBD5E1), fontWeight: FontWeight.w600)),
            Text(money(_total), style: h(32, color: Colors.white)),
            const SizedBox(height: 6),
            Text(left > 0 ? 'Left: ${money(left)}' : (left < 0 ? 'Change: ${money(-left)}' : 'Fully paid'),
                style: h(16, color: left > 0 ? C.gold : Colors.white)),
          ]),
        ),
        const Label('How is the customer paying?'),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.6,
          children: [
            for (final m in _methods)
              OutlinedButton.icon(
                onPressed: () => _addPay(m),
                icon: Icon(_icon(s(m['kind']))),
                label: Text(s(m['name']), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
        if (_pays.isNotEmpty) ...[
          const Label('Payments'),
          Container(
            decoration: box(),
            child: Column(children: [
              for (final p in _pays)
                ListTile(
                  leading: Icon(_icon(p.kind)),
                  title: Text(p.name),
                  subtitle: p.ref.isEmpty ? null : Text(p.ref),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(money(p.amount), style: h(14)),
                    IconButton(onPressed: () => setState(() => _pays.remove(p)), icon: const Icon(Icons.close)),
                  ]),
                ),
            ]),
          ),
        ],
        if (_pays.isEmpty && _methods.isNotEmpty) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              final cash = _methods.firstWhere((m) => s(m['kind']) == 'cash', orElse: () => _methods.first);
              setState(() => _pays.add(Pay(n(cash['id']), s(cash['kind']), s(cash['name']), _total)));
            },
            style: FilledButton.styleFrom(backgroundColor: C.gold),
            icon: const Icon(Icons.flash_on),
            label: Text('Exact cash ${money(_total)}'),
          ),
        ],
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: FilledButton(
            onPressed: _busy || left > 0.004 || _pays.isEmpty ? null : _finish,
            style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 56)),
            child: Text(_busy ? 'Saving...' : 'Complete sale'),
          ),
        ),
      ),
    );
  }

  IconData _icon(String kind) => switch (kind) {
        'cash' => Icons.payments_outlined,
        'mpesa' => Icons.phone_android,
        'card' => Icons.credit_card,
        'credit' => Icons.account_balance_wallet_outlined,
        _ => Icons.attach_money,
      };
}

Future<bool> printSale(int id, {bool copy = false}) async {
  final sale = await Sales.sale(id);
  if (sale == null) return false;
  final ok = await Printer.printLines(
      Printer.saleLines(sale, await Sales.lines(id), await Sales.payments(id), copy: copy), '${copy ? 'Copy ' : ''}${sale['number']}');
  if (copy) {
    final db = await Db.get();
    await db.rawUpdate('UPDATE sales SET copies = copies + 1 WHERE id = ?', [id]);
  }
  return ok;
}

class DoneScreen extends StatelessWidget {
  final int saleId;
  final double change;
  const DoneScreen({super.key, required this.saleId, required this.change});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              const Spacer(),
              Container(
                width: 92,
                height: 92,
                decoration: const BoxDecoration(color: C.greenLight, shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded, color: C.green, size: 56),
              ),
              const SizedBox(height: 18),
              Text('Sale complete', style: h(26)),
              if (change > 0) ...[
                const SizedBox(height: 8),
                Text('Change: ${money(change)}', style: h(30, color: C.gold)),
              ],
              const Spacer(),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final ok = await printSale(saleId);
                      if (context.mounted) toast(context, ok ? 'Printed.' : 'Printer not found. Choose it in More > Printer.');
                    },
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Print'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SaleDetail(saleId: saleId))),
                    icon: const Icon(Icons.receipt_outlined),
                    label: const Text('Receipt'),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 56)),
                child: const Text('New sale'),
              ),
            ]),
          ),
        ),
      );
}
