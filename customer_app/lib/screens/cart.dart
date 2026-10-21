import 'package:flutter/material.dart';
import '../store.dart';
import '../ui.dart';
import 'checkout.dart';
import 'shell.dart';

class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final ids = store.cart.keys.where((id) => store.product(id) != null).toList();
          if (ids.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: const BoxDecoration(color: C.greenLight, shape: BoxShape.circle),
                    child: const Icon(Icons.shopping_cart_outlined, color: C.green, size: 40),
                  ),
                  const SizedBox(height: 16),
                  Text('Your cart is empty', style: head(18)),
                  const SizedBox(height: 6),
                  const Text('Add fresh produce from the shop.', style: TextStyle(color: C.muted)),
                  const SizedBox(height: 20),
                  SizedBox(width: 200, child: PrimaryButton('Start shopping', onTap: () => openShop())),
                ]),
              ),
            );
          }
          return Column(children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                children: [
                  Row(children: [
                    Expanded(child: Text('My Cart', style: head(20))),
                    TextButton(
                      onPressed: () => store.clearCart(),
                      style: TextButton.styleFrom(foregroundColor: C.muted),
                      child: const Text('Clear'),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Container(
                    decoration: cardBox(),
                    child: Column(children: [
                      for (var i = 0; i < ids.length; i++) ...[
                        if (i > 0) const Divider(height: 1, indent: 12, endIndent: 12, color: C.line),
                        _CartLine(ids[i]),
                      ],
                    ]),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: cardBox(),
                    child: Column(children: [
                      _row('Subtotal (${store.cartCount} items)', money(store.cartTotal)),
                      const SizedBox(height: 8),
                      _row('Delivery', 'Set at checkout'),
                      const Divider(height: 22, color: C.line),
                      Row(children: [
                        Expanded(child: Text('Total so far', style: head(16.5, w: FontWeight.w600))),
                        Text(money(store.cartTotal), style: head(16.5, w: FontWeight.w600)),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: C.greenLight, borderRadius: BorderRadius.circular(14)),
                    child: const Row(children: [
                      Icon(Icons.location_on_outlined, color: C.greenDark),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text("You'll pin your exact location next. Delivery is priced by distance.",
                            style: TextStyle(color: C.greenDark, fontSize: 13.5)),
                      ),
                    ]),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: PrimaryButton(
                'Checkout',
                icon: Icons.arrow_forward_rounded,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CheckoutScreen())),
              ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _row(String a, String b) => Row(children: [
        Expanded(child: Text(a, style: const TextStyle(color: C.muted, fontSize: 14.5))),
        Text(b, style: const TextStyle(fontSize: 14.5)),
      ]);
}

class _CartLine extends StatelessWidget {
  final int id;
  const _CartLine(this.id);
  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final p = store.product(id)!;
    final q = store.qty(id);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Container(
          width: 62,
          height: 62,
          clipBehavior: Clip.antiAlias,
          decoration: cardBox(12),
          child: NetImage(p.thumb),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: head(14, w: FontWeight.w500)),
            Text('${money(p.price)} each', style: const TextStyle(fontSize: 13, color: C.muted)),
            Text(money(p.price * q), style: head(14.5, w: FontWeight.w600, color: C.green)),
          ]),
        ),
        QtyControl(p, width: 100),
      ]),
    );
  }
}
