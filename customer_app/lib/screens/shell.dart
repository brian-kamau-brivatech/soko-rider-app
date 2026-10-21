import 'package:flutter/material.dart';
import '../store.dart';
import '../ui.dart';
import 'cart.dart';
import 'home.dart';
import 'orders.dart';
import 'shop.dart';

/// Which bottom tab is showing. Screens change it to jump between tabs.
final ValueNotifier<int> currentTab = ValueNotifier<int>(0);

/// Category the Shop tab should open on (null = all).
final ValueNotifier<int?> shopCategory = ValueNotifier<int?>(null);

void openShop([int? categoryId]) {
  shopCategory.value = categoryId;
  currentTab.value = 1;
}

class Shell extends StatelessWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: currentTab,
      builder: (context, tab, _) => PopScope(
        canPop: tab == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) currentTab.value = 0;
        },
        child: Scaffold(
          body: IndexedStack(index: tab, children: const [
            HomeScreen(),
            ShopScreen(),
            CartScreen(),
            OrdersScreen(),
          ]),
          bottomNavigationBar: ListenableBuilder(
            listenable: AppStore.instance,
            builder: (context, _) => _BottomBar(tab: tab, cartCount: AppStore.instance.cartCount),
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final int tab;
  final int cartCount;
  const _BottomBar({required this.tab, required this.cartCount});

  @override
  Widget build(BuildContext context) {
    Widget item(int i, IconData off, IconData on, String label, {int badge = 0}) {
      final sel = tab == i;
      return Expanded(
        child: InkWell(
          onTap: () => currentTab.value = i,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Stack(clipBehavior: Clip.none, children: [
              Icon(sel ? on : off, color: sel ? C.green : const Color(0xFF8A928D), size: 25),
              if (badge > 0)
                Positioned(
                  top: -6,
                  right: -10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(10)),
                    child: Text('$badge', style: head(10.5, color: Colors.white)),
                  ),
                ),
            ]),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
                  color: sel ? C.green : const Color(0xFF8A928D),
                )),
          ]),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: C.line))),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(children: [
            item(0, Icons.home_outlined, Icons.home_rounded, 'Home'),
            item(1, Icons.storefront_outlined, Icons.storefront_rounded, 'Shop'),
            item(2, Icons.shopping_cart_outlined, Icons.shopping_cart_rounded, 'Cart', badge: cartCount),
            item(3, Icons.receipt_long_outlined, Icons.receipt_long_rounded, 'Orders'),
          ]),
        ),
      ),
    );
  }
}
