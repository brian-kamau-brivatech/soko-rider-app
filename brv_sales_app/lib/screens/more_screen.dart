import 'package:flutter/material.dart';
import '../perms.dart';
import '../session.dart';
import '../settings.dart';
import '../ui.dart';
import 'accounting_screen.dart';
import 'customers_screen.dart';
import 'sales_screen.dart';
import 'settings_screen.dart';
import 'shell.dart';
import 'shift_screen.dart';
import 'users_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final ses = Session.i;
    void go(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    Widget item(IconData i, String t, Widget w, {String? sub}) => ListTile(
          leading: Icon(i),
          title: Text(t, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: sub == null ? null : Text(sub),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => go(w),
        );
    return Scaffold(
      appBar: const TopBar('More'),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: box(color: C.ink, border: false),
          child: Row(children: [
            Avatar(ses.name, size: 50, bg: C.gold, fg: Colors.white),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(ses.name, style: h(18, color: Colors.white)),
                Text('${ses.owner ? 'Owner' : ses.roleName} · ${Settings.i.businessName}', style: const TextStyle(color: Color(0xFFCBD5E1))),
              ]),
            ),
            IconButton(onPressed: () => ses.lock(), icon: const Icon(Icons.logout, color: Colors.white)),
          ]),
        ),
        const SizedBox(height: 16),
        Group('Selling', [
          if (ses.can(P.shift)) item(Icons.lock_clock_outlined, 'Shift (cash drawer)', const ShiftScreen(), sub: ses.shift == null ? 'Closed' : 'Open'),
          item(Icons.receipt_long_outlined, ses.can(P.allSales) ? 'Sales' : 'My sales', const SalesScreen()),
          if (ses.can(P.customers) || ses.can(P.customerPay)) item(Icons.people_outline, 'Customers', const CustomersScreen(), sub: 'Credit, balances, payments'),
        ]),
        if (ses.can(P.accounting) || ses.can(P.expenses))
          Group('Money', [
            if (ses.can(P.accounting)) item(Icons.account_balance_outlined, 'Accounting', const AccountingScreen(), sub: 'P&L, balance sheet, journal'),
            if (ses.can(P.expenses)) item(Icons.receipt_outlined, 'Expenses', const ExpensesScreen()),
          ]),
        if (ses.can(P.users) || ses.can(P.roles) || ses.can(P.settings) || ses.can(P.backup))
          Group('Administration', [
            if (ses.can(P.users)) item(Icons.manage_accounts_outlined, 'Users and PINs', const UsersScreen()),
            if (ses.can(P.roles) && !ses.can(P.users)) item(Icons.admin_panel_settings_outlined, 'Roles and rights', const RolesScreen()),
            if (ses.can(P.settings)) item(Icons.store_outlined, 'Business settings', const BusinessSettings()),
            if (ses.can(P.settings)) item(Icons.payments_outlined, 'Payment methods', const PayMethodsScreen()),
            if (ses.can(P.settings)) item(Icons.print_outlined, 'Printer', const PrinterScreen()),
            if (ses.can(P.backup)) item(Icons.backup_outlined, 'Backup and restore', const BackupScreen()),
            if (ses.owner || ses.can(P.users)) item(Icons.history, 'Activity log', const AuditScreen()),
          ]),
        if (!ses.can(P.settings))
          Group('Device', [item(Icons.print_outlined, 'Printer', const PrinterScreen())]),
        const SizedBox(height: 8),
        Center(child: Image.asset('assets/brv_logo.png', height: 70)),
        const Center(child: Text('BRV Pos Sales · works offline', style: TextStyle(color: C.muted, fontSize: 12))),
      ]),
    );
  }
}
