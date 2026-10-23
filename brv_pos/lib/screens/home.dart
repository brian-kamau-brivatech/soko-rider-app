import 'package:flutter/material.dart';
import '../ui.dart';
import 'items_screen.dart';
import 'sales_screen.dart';
import 'sell_screen.dart';
import 'settings_screen.dart';

final ValueNotifier<int> homeTab = ValueNotifier<int>(0);

class Home extends StatelessWidget {
  const Home({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: homeTab,
        builder: (context, t, _) => Scaffold(
          body: IndexedStack(index: t, children: const [
            SellScreen(),
            SalesScreen(),
            ItemsScreen(),
            SettingsScreen(),
          ]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: t,
            onDestinationSelected: (v) => homeTab.value = v,
            backgroundColor: Colors.white,
            indicatorColor: C.brandLight,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.point_of_sale_outlined), selectedIcon: Icon(Icons.point_of_sale), label: 'Sell'),
              NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Sales'),
              NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: 'Items'),
              NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
            ],
          ),
        ),
      );
}
