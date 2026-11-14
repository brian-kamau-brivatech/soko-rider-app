import 'package:flutter/material.dart';
import '../ui.dart';
import 'mgr_dashboard.dart';
import 'mgr_items.dart';
import 'mgr_purchase.dart';
import 'mgr_requests.dart';
import 'mgr_sheets.dart';

final ValueNotifier<int> mgrTab = ValueNotifier<int>(0);

/// Set before switching to the Sheets tab to show only sheets with differences / waiting for approval.
bool mgrSheetsIssues = false;

class MgrShell extends StatelessWidget {
  const MgrShell({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: mgrTab,
        builder: (context, t, _) => Scaffold(
          body: IndexedStack(index: t, children: const [MgrDashboard(), MgrRequests(), MgrSheets(), MgrItems(), MgrPurchases()]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: t,
            onDestinationSelected: (v) => mgrTab.value = v,
            backgroundColor: Colors.white,
            indicatorColor: C.greenLight,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard_rounded), label: 'Today'),
              NavigationDestination(icon: Icon(Icons.assignment_outlined), selectedIcon: Icon(Icons.assignment_rounded), label: 'Requests'),
              NavigationDestination(icon: Icon(Icons.fact_check_outlined), selectedIcon: Icon(Icons.fact_check_rounded), label: 'Sheets'),
              NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2_rounded), label: 'Items'),
              NavigationDestination(icon: Icon(Icons.shopping_cart_outlined), selectedIcon: Icon(Icons.shopping_cart_rounded), label: 'Buy'),
            ],
          ),
        ),
      );
}
