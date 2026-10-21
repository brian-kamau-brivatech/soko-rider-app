import 'package:flutter/material.dart';
import '../store.dart';
import '../ui.dart';
import 'alert_screen.dart';
import 'home.dart';
import 'orders.dart';
import 'riders.dart';
import 'settings.dart';

final ValueNotifier<int> tab = ValueNotifier<int>(0);

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  bool _alertOpen = false;

  @override
  void initState() {
    super.initState();
    Store.i.alert.addListener(_onAlert);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAlert());
  }

  @override
  void dispose() {
    Store.i.alert.removeListener(_onAlert);
    super.dispose();
  }

  Future<void> _onAlert() async {
    final a = Store.i.alert.value;
    if (a == null || _alertOpen || !mounted) return;
    _alertOpen = true;
    await Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => AlertScreen(alert: a)));
    _alertOpen = false;
    if (Store.i.alert.value != null && Store.i.alert.value != a) _onAlert();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: tab,
      builder: (context, t, _) => Scaffold(
        body: IndexedStack(index: t, children: const [HomeScreen(), OrdersScreen(), RidersScreen(), SettingsScreen()]),
        bottomNavigationBar: ListenableBuilder(
          listenable: Store.i,
          builder: (context, _) {
            final newCount = Store.i.board?.counts['new'] ?? 0;
            return NavigationBar(
              selectedIndex: t,
              onDestinationSelected: (v) => tab.value = v,
              backgroundColor: Colors.white,
              indicatorColor: C.greenLight,
              destinations: [
                const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
                NavigationDestination(
                  icon: Badge(isLabelVisible: newCount > 0, label: Text('$newCount'), child: const Icon(Icons.receipt_long_outlined)),
                  selectedIcon: Badge(isLabelVisible: newCount > 0, label: Text('$newCount'), child: const Icon(Icons.receipt_long_rounded)),
                  label: 'Orders',
                ),
                const NavigationDestination(icon: Icon(Icons.two_wheeler_outlined), selectedIcon: Icon(Icons.two_wheeler_rounded), label: 'Riders'),
                const NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: 'Settings'),
              ],
            );
          },
        ),
      ),
    );
  }
}
