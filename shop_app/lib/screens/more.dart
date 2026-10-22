import 'package:flutter/material.dart';
import '../store.dart';
import '../ui.dart';
import 'riders.dart';
import 'session_screen.dart';
import 'settings.dart';
import 'stock.dart';

/// Stock, Riders and Settings.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget item(IconData icon, String title, String sub, Widget page) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: card(),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: CircleAvatar(backgroundColor: C.greenLight, child: Icon(icon, color: C.green)),
            title: Text(title, style: h(16)),
            subtitle: Text(sub),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
          ),
        );
    return SafeArea(
      bottom: false,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
        Text('More', style: h(22)),
        const SizedBox(height: 14),
        if (Store.i.cashiersOn && Store.i.cashierName.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: card(),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              leading: const CircleAvatar(backgroundColor: C.navy, child: Icon(Icons.badge_rounded, color: Colors.white)),
              title: Text(Store.i.cashierName, style: h(16)),
              subtitle: Text('${Store.i.isManager ? 'Manager' : 'Cashier'} · tap to switch cashier'),
              trailing: const Icon(Icons.logout_rounded),
              onTap: () => Store.i.clearCashier(),
            ),
          ),
        item(Icons.lock_clock_rounded, 'POS session', 'Open or close the day (cash count)', const SessionScreen()),
        item(Icons.inventory_2_rounded, 'Stock', 'On hand and inventory moves', const StockScreen()),
        item(Icons.two_wheeler_rounded, 'Riders', 'Who is free, busy or offline', const _Page('Riders', RidersScreen())),
        item(Icons.settings_rounded, 'Settings', 'Alerts, printer, this device', const _Page('Settings', SettingsScreen())),
      ]),
    );
  }
}

class _Page extends StatelessWidget {
  final String title;
  final Widget child;
  const _Page(this.title, this.child);
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(backgroundColor: Colors.white, surfaceTintColor: Colors.white, title: Text(title, style: h(18))),
        body: child,
      );
}
