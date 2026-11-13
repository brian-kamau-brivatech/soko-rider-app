import 'package:flutter/material.dart';
import '../ui.dart';
import 'mgr_dashboard.dart';
import 'mgr_requests.dart';
import 'mgr_sheets.dart';

final ValueNotifier<int> mgrTab = ValueNotifier<int>(0);

class MgrShell extends StatelessWidget {
  const MgrShell({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: mgrTab,
        builder: (context, t, _) => Scaffold(
          body: IndexedStack(index: t, children: const [MgrDashboard(), MgrRequests(), MgrSheets()]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: t,
            onDestinationSelected: (v) => mgrTab.value = v,
            backgroundColor: Colors.white,
            indicatorColor: C.greenLight,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard_rounded), label: 'Today'),
              NavigationDestination(icon: Icon(Icons.assignment_outlined), selectedIcon: Icon(Icons.assignment_rounded), label: 'Requests'),
              NavigationDestination(icon: Icon(Icons.fact_check_outlined), selectedIcon: Icon(Icons.fact_check_rounded), label: 'Stock sheets'),
            ],
          ),
        ),
      );
}
