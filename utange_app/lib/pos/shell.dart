import 'package:flutter/material.dart';
import '../ui.dart';
import 'more_screen.dart';
import 'requests_screen.dart';
import 'sales_screen.dart';
import 'sell_screen.dart';

final ValueNotifier<int> posTab = ValueNotifier<int>(0);

class PosShell extends StatelessWidget {
  const PosShell({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: posTab,
        builder: (context, t, _) => Scaffold(
          body: IndexedStack(index: t, children: const [SellScreen(), SalesScreen(), RequestsScreen(), MoreScreen()]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: t,
            onDestinationSelected: (v) => posTab.value = v,
            backgroundColor: Colors.white,
            indicatorColor: C.greenLight,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.point_of_sale_outlined), selectedIcon: Icon(Icons.point_of_sale_rounded), label: 'Sell'),
              NavigationDestination(icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart_rounded), label: 'Sales'),
              NavigationDestination(icon: Icon(Icons.assignment_outlined), selectedIcon: Icon(Icons.assignment_rounded), label: 'Requests'),
              NavigationDestination(icon: Icon(Icons.more_horiz_rounded), selectedIcon: Icon(Icons.more_horiz_rounded), label: 'More'),
            ],
          ),
        ),
      );
}
