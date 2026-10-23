import 'package:flutter/material.dart';
import '../db.dart';
import '../kra.dart';
import '../sales.dart';
import '../settings.dart';
import '../ui.dart';
import 'sales_screen.dart';
import 'items_screen.dart';
import 'pay_screen.dart';

class CartLine {
  final Map<String, dynamic> item;
  double qty;
  double discount; // %
  double price; // unit price incl. VAT, entered at sale
  CartLine(this.item, {required this.price, this.qty = 1, this.discount = 0});
  SaleLineCalc calc() => SaleLineCalc(
        itemId: item['id'] as int,
        itemCd: '${item['item_cd']}',
        itemClsCd: '${item['cls_cd']}',
        name: '${item['name']}',
        barcode: '${item['barcode'] ?? ''}',
        pkgUnit: '${item['pkg_unit']}',
        qtyUnit: '${item['qty_unit']}',
        tax: '${item['tax']}',
        qty: qty,
        priceIncl: price,
        discountRate: discount,
      );
}

/// The open cart; kept while you switch tabs.
class Cart extends ChangeNotifier {
  static final Cart i = Cart();
  final List<CartLine> lines = [];

  void add(Map<String, dynamic> item, {required double price, double qty = 1}) {
    for (final l in lines) {
      if (l.item['id'] == item['id'] && l.discount == 0 && l.price == price) {
        l.qty = r2(l.qty + qty);
        notifyListeners();
        return;
      }
    }
    lines.add(CartLine(item, price: price, qty: r2(qty)));
    notifyListeners();
  }

  void remove(CartLine l) {
    lines.remove(l);
    notifyListeners();
  }

  void clear() {
    lines.clear();
    notifyListeners();
  }

  void changed() => notifyListeners();

  List<SaleLineCalc> calcs() => lines.map((l) => l.calc()).toList();
  double get total => r2(calcs().fold<double>(0, (a, c) => a + c.total));
  double get count => lines.fold<double>(0, (a, l) => a + l.qty);
}

class SellScreen extends StatefulWidget {
  const SellScreen({super.key});
  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  List<Map<String, dynamic>> _items = [];
  final _search = TextEditingController();
  String _q = '';
  Sale? _pending;

  @override
  void initState() {
    super.initState();
    _load();
    itemsVersion.addListener(_load);
    salesVersion.addListener(_checkPending);
    Cart.i.addListener(_rebuild);
  }

  @override
  void dispose() {
    itemsVersion.removeListener(_load);
    salesVersion.removeListener(_checkPending);
    Cart.i.removeListener(_rebuild);
    _search.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }


  Future<void> _load() async {
    final db = await Db.get();
    final r = await db.query('items', where: 'active = 1', orderBy: 'name COLLATE NOCASE');
    if (mounted) setState(() => _items = r.map((e) => Map<String, dynamic>.from(e)).toList());
    _checkPending();
  }

  Future<void> _checkPending() async {
    final p = await Sales.pendingSale();
    if (mounted) setState(() => _pending = p);
  }

  void _onSubmitted(String v) {
    // A barcode scanner types the code and presses Enter: add it straight away.
    final code = v.trim();
    if (code.isEmpty) return;
    final hit = _items.where((e) => '${e['barcode']}' == code || '${e['item_cd']}' == code).toList();
    if (hit.length == 1) {
      _search.clear();
      setState(() => _q = '');
      _addItem(hit.first);
    }
  }

  /// Prices are not fixed: ask the VAT-inclusive price (and quantity) for each item.
  Future<void> _addItem(Map<String, dynamic> it) async {
    final dflt = (it['price'] as num?)?.toDouble() ?? 0;
    final price = TextEditingController(text: dflt > 0 ? dflt.toStringAsFixed(2) : '');
    final qty = TextEditingController(text: '1');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${it['name']}', style: h(19)),
          Text('Tax group ${it['tax']} · ${Kra.find(Kra.taxTypes, '${it['tax']}')?.name ?? ''}',
              style: const TextStyle(color: C.muted)),
          const SizedBox(height: 14),
          TextField(
            controller: price,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: h(22),
            decoration: field('Unit price (VAT inclusive)', hint: '0.00'),
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 12),
          Row(children: [
            IconButton.filledTonal(
              onPressed: () {
                final v = (double.tryParse(qty.text) ?? 1) - 1;
                if (v > 0) qty.text = qtyText(v);
              },
              icon: const Icon(Icons.remove_rounded),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: qty,
                textAlign: TextAlign.center,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: field('Quantity'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: () => qty.text = qtyText((double.tryParse(qty.text) ?? 0) + 1),
              icon: const Icon(Icons.add_rounded),
            ),
          ]),
          const SizedBox(height: 16),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.add_shopping_cart_rounded),
              label: const Text('Add to sale'),
            ),
          ),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    final p = double.tryParse(price.text.trim().replaceAll(',', ''));
    final q = double.tryParse(qty.text.trim().replaceAll(',', '')) ?? 1;
    if (p == null || p <= 0) {
      toast(context, 'Enter the price for ${it['name']}.');
      return;
    }
    if (q <= 0) return;
    Cart.i.add(it, price: r2(p), qty: q);
  }

  Future<void> _editLine(CartLine l) async {
    final qty = TextEditingController(text: qtyText(l.qty));
    final pr = TextEditingController(text: l.price.toStringAsFixed(2));
    final dc = TextEditingController(text: l.discount == 0 ? '' : l.discount.toStringAsFixed(l.discount % 1 == 0 ? 0 : 2));
    final res = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${l.item['name']}', style: h(18)),
          Text('${money(l.price)} each · tax ${l.item['tax']}', style: const TextStyle(color: C.muted)),
          const SizedBox(height: 14),
          Row(children: [
            IconButton.filledTonal(
              onPressed: () {
                final v = (double.tryParse(qty.text) ?? 1) - 1;
                if (v > 0) qty.text = qtyText(v);
              },
              icon: const Icon(Icons.remove_rounded),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: qty,
                textAlign: TextAlign.center,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: field('Quantity'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: () => qty.text = qtyText((double.tryParse(qty.text) ?? 0) + 1),
              icon: const Icon(Icons.add_rounded),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: pr,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: field('Unit price (VAT inclusive)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: dc,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: field('Discount %', hint: '0'),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, 'remove'),
                style: OutlinedButton.styleFrom(foregroundColor: C.red),
                child: const Text('Remove'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: FilledButton(onPressed: () => Navigator.pop(ctx, 'ok'), child: const Text('Done'))),
          ]),
        ]),
      ),
    );
    if (res == 'remove') {
      Cart.i.remove(l);
    } else if (res == 'ok') {
      final q = double.tryParse(qty.text.trim().replaceAll(',', '')) ?? l.qty;
      final d = double.tryParse(dc.text.trim()) ?? 0;
      if (q <= 0) {
        Cart.i.remove(l);
      } else {
        l.qty = r2(q);
        final np = double.tryParse(pr.text.trim().replaceAll(',', ''));
        if (np != null && np > 0) l.price = r2(np);
        l.discount = d.clamp(0, 100).toDouble();
        Cart.i.changed();
      }
    }
  }

  Future<void> _charge() async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const PayScreen()));
    if (done == true) Cart.i.clear();
    _checkPending();
  }

  Widget _cartList(Cart cart, bool shrink) => ListView.builder(
        shrinkWrap: shrink,
        itemCount: cart.lines.length,
        itemBuilder: (_, i) {
          final l = cart.lines[i];
          final c = l.calc();
          return ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            title: Text('${l.item['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: h(14, w: FontWeight.w700)),
            subtitle: Text('${qtyText(l.qty)} × ${money(l.price, symbol: false)}'
                '${l.discount > 0 ? ' · −${l.discount.toStringAsFixed(l.discount % 1 == 0 ? 0 : 2)}%' : ''}'),
            trailing: Text(money(c.total, symbol: false), style: h(14.5)),
            onTap: () => _editLine(l),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final s = Settings.i;
    final q = _q.toLowerCase();
    final list = q.isEmpty
        ? _items
        : _items.where((e) => '${e['name']} ${e['barcode']} ${e['item_cd']}'.toLowerCase().contains(q)).toList();
    final cart = Cart.i;
    final wide = MediaQuery.of(context).size.width >= 700;

    final products = Column(children: [
      if (_pending != null)
        Material(
          color: C.amberLight,
          child: ListTile(
            leading: const Icon(Icons.hourglass_top_rounded, color: C.amber),
            title: Text('Sale ${_pending!.number} is waiting for the VSCU', style: h(14, color: C.amber)),
            subtitle: const Text('Tap here and Retry it before the next sale.'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SalesScreen())),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: TextField(
          controller: _search,
          decoration: field('Search or scan barcode', prefix: const Icon(Icons.search_rounded)).copyWith(
            suffixIcon: _q.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _search.clear();
                      setState(() => _q = '');
                    }),
          ),
          onChanged: (v) => setState(() => _q = v.trim()),
          onSubmitted: _onSubmitted,
        ),
      ),
      Expanded(
        child: _items.isEmpty
            ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const EmptyNote(Icons.inventory_2_outlined, 'No items yet.'),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ItemsScreen())),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add items'),
                ),
              ])
            : list.isEmpty
                ? EmptyNote(Icons.search_off_rounded, 'Nothing matches "$_q".')
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 190, mainAxisExtent: 96, crossAxisSpacing: 8, mainAxisSpacing: 8),
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final it = list[i];
                      final inCart = cart.lines.where((l) => l.item['id'] == it['id']).fold<double>(0, (a, l) => a + l.qty);
                      return InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _addItem(it),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: card(14).copyWith(
                            color: inCart > 0 ? C.brandLight : Colors.white,
                            border: Border.all(color: inCart > 0 ? C.brand2 : C.line),
                          ),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(
                              child: Text('${it['name']}',
                                  maxLines: 2, overflow: TextOverflow.ellipsis, style: h(14, w: FontWeight.w700)),
                            ),
                            Row(children: [
                              Expanded(child: Text(((it['price'] as num?) ?? 0) > 0 ? money((it['price'] as num).toDouble(), symbol: false) : 'Enter price', style: h(15, color: C.brand))),
                              if (inCart > 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(99)),
                                  child: Text(qtyText(inCart), style: h(12, color: Colors.white)),
                                ),
                            ]),
                          ]),
                        ),
                      );
                    },
                  ),
      ),
    ]);

    final cartPanel = Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: C.line), left: BorderSide(color: C.line)),
      ),
      child: Column(mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min, children: [
        if (cart.lines.isNotEmpty)
          wide
              ? Expanded(child: _cartList(cart, false))
              : ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.3),
                  child: _cartList(cart, true),
                ),
        if (wide && cart.lines.isEmpty) const Expanded(child: EmptyNote(Icons.shopping_basket_outlined, 'Tap items to add them.')),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Row(children: [
              if (cart.lines.isNotEmpty)
                IconButton(
                  tooltip: 'Clear',
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Clear the cart?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
                        ],
                      ),
                    );
                    if (ok == true) cart.clear();
                  },
                  icon: const Icon(Icons.delete_outline_rounded, color: C.red),
                ),
              Expanded(
                child: SizedBox(
                  height: 54,
                  child: FilledButton(
                    onPressed: cart.lines.isEmpty || !s.ready ? null : _charge,
                    style: FilledButton.styleFrom(backgroundColor: C.green),
                    child: Text(
                      cart.lines.isEmpty ? 'Charge' : 'Charge  ${money(cart.total)}',
                      style: h(17, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('New sale'),
        actions: [
          if (cart.lines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Pill('${qtyText(cart.count)} item${cart.count == 1 ? '' : 's'}', fg: C.brand, bg: C.brandLight),
            ),
        ],
      ),
      body: wide
          ? Row(children: [Expanded(child: products), SizedBox(width: 360, child: cartPanel)])
          : Column(children: [Expanded(child: products), cartPanel]),
    );
  }
}
