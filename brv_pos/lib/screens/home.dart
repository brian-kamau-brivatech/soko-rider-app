import 'dart:io';
import 'package:flutter/material.dart';
import '../backup.dart';
import '../kra_check.dart';
import '../reports.dart';
import '../sales.dart';
import '../session.dart';
import '../settings.dart';
import '../ui.dart';
import 'customers_screen.dart';
import 'item_form.dart';
import 'items_screen.dart';
import 'reports_screen.dart';
import 'sales_screen.dart';
import 'sell_screen.dart';
import 'settings_screen.dart';
import 'users_screen.dart';

/// Home: big tiles for everything, like a fiscal POS terminal.
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  ReportData? _today;
  int _waiting = 0;
  int _unconfirmed = 0;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
    salesVersion.addListener(_load);
    Settings.i.addListener(_rebuild);
    // Confirm recent sales with KRA in the background.
    Future.microtask(KraCheck.checkRecent);
    Future.microtask(Backup.auto);
  }

  @override
  void dispose() {
    salesVersion.removeListener(_load);
    Settings.i.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final day = Reports.ymd(DateTime.now());
      final d = await Reports.build(day, day);
      final p = await Sales.pendingSale();
      final u = await KraCheck.unconfirmedCount();
      if (mounted) {
        setState(() {
          _today = d;
          _waiting = p == null ? 0 : 1;
          _unconfirmed = u;
          _error = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _go(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    _load();
  }

  Widget _logoBadge() {
    final path = Settings.i.logoPath;
    final f = path.isNotEmpty && File(path).existsSync() ? File(path) : null;
    return Container(
      margin: const EdgeInsets.only(right: 12),
      height: 40,
      constraints: const BoxConstraints(maxWidth: 110, minWidth: 40),
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: f == null ? Image.asset('assets/brv_mark.png', fit: BoxFit.contain) : Image.file(f, fit: BoxFit.contain),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Settings.i;
    final se = Session.i;
    final admin = se.admin;
    final tiles = <(IconData, String, Widget, bool)>[
      (Icons.add_shopping_cart_rounded, 'New sale', const SellScreen(), true),
      (Icons.receipt_long_rounded, 'Receipts / Invoices', const SalesScreen(), false),
      if (admin) (Icons.library_add_rounded, 'Add item', const ItemForm(), false),
      (Icons.inventory_2_rounded, 'Items', const ItemsScreen(), false),
      (Icons.people_alt_rounded, 'Customers', const CustomersScreen(), false),
      (Icons.bar_chart_rounded, 'Sales reports', const ReportsScreen(), false),
      if (admin) (Icons.manage_accounts_rounded, 'Users', const UsersScreen(), false),
      if (admin) (Icons.settings_rounded, 'Settings', const SettingsScreen(), false),
    ];
    final wide = MediaQuery.of(context).size.width >= 600;
    final d = _today;

    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard'), actions: [_logoBadge()]),
      drawer: _drawer(),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 24), children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [C.brand, C.brand2], begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(s.shopName, maxLines: 1, overflow: TextOverflow.ellipsis, style: h(17, color: Colors.white)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(color: C.gold, borderRadius: BorderRadius.circular(99)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.circle, size: 8, color: Colors.white),
                    const SizedBox(width: 5),
                    Text('eTIMS LIVE', style: h(11, color: Colors.white)),
                  ]),
                ),
              ]),
              Text('PIN ${s.tin} · Branch ${s.bhfId}', style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
              const SizedBox(height: 14),
              const Text("TODAY'S SALES", style: TextStyle(color: C.gold, fontWeight: FontWeight.w800, letterSpacing: 1, fontSize: 12)),
              Text(d == null ? '…' : money(d.net), style: h(30, color: Colors.white)),
              const SizedBox(height: 4),
              Text(
                d == null ? '' : '${d.salesCount} receipts · VAT ${money(d.vat, symbol: false)}'
                    '${d.creditCount > 0 ? ' · ${d.creditCount} credit notes' : ''}',
                style: const TextStyle(color: Colors.white70),
              ),
            ]),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: C.redLight, borderRadius: BorderRadius.circular(14)),
              child: SelectableText('Could not load today\'s totals: $_error', style: const TextStyle(color: C.red)),
            ),
          ],
          if (_waiting > 0) ...[
            const SizedBox(height: 12),
            Material(
              color: C.amberLight,
              borderRadius: BorderRadius.circular(14),
              child: ListTile(
                leading: const Icon(Icons.hourglass_top_rounded, color: C.amber),
                title: Text('A sale is waiting for the VSCU', style: h(14, color: C.amber)),
                subtitle: const Text('Open it and tap Retry.'),
                onTap: () => _go(const SalesScreen()),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Material(
            color: _unconfirmed == 0 ? C.greenLight : C.amberLight,
            borderRadius: BorderRadius.circular(14),
            child: ListTile(
              leading: Icon(_unconfirmed == 0 ? Icons.cloud_done_rounded : Icons.cloud_sync_rounded,
                  color: _unconfirmed == 0 ? C.green : C.amber),
              title: Text(
                _unconfirmed == 0 ? 'All sales confirmed at KRA' : '$_unconfirmed sale(s) not yet confirmed at KRA',
                style: h(14, color: _unconfirmed == 0 ? C.green : C.amber),
              ),
              subtitle: Text(_unconfirmed == 0 ? 'Last 30 days' : 'Tap to see them and check again'),
              onTap: () => _go(const SalesScreen()),
            ),
          ),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: wide ? 4 : 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.15,
            children: [for (final t in tiles) _tile(t.$1, t.$2, t.$4, () => _go(t.$3))],
          ),
        ]),
      ),
    );
  }

  Widget _tile(IconData icon, String label, bool primary, VoidCallback onTap) => Material(
        color: primary ? C.brand : Colors.white,
        borderRadius: BorderRadius.circular(18),
        elevation: primary ? 3 : 0,
        shadowColor: C.brand.withValues(alpha: 0.4),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: primary ? null : Border.all(color: C.line),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: primary ? C.gold : C.brandLight,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, size: 30, color: primary ? Colors.white : C.brand),
              ),
              const SizedBox(height: 10),
              Text(label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: h(14.5, w: FontWeight.w700, color: primary ? Colors.white : C.ink)),
            ]),
          ),
        ),
      );

  Widget _drawer() {
    final se = Session.i;
    return Drawer(
      child: Column(children: [
        Container(
          width: double.infinity,
          color: C.brand,
          padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 20, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
              child: Image.asset('assets/brv_mark.png', height: 44),
            ),
            const SizedBox(height: 12),
            Text(se.name, style: h(18, color: Colors.white)),
            Text('${se.username} · ${se.admin ? 'Admin' : 'Cashier'}', style: const TextStyle(color: C.gold, fontWeight: FontWeight.w600)),
          ]),
        ),
        ListTile(
          leading: const Icon(Icons.lock_reset_rounded, color: C.brand),
          title: const Text('Change username or password'),
          onTap: () {
            Navigator.pop(context);
            _go(ChangeCredentialsScreen(user: se.user!));
          },
        ),
        ListTile(
          leading: const Icon(Icons.logout_rounded, color: C.red),
          title: const Text('Sign out'),
          onTap: () {
            Navigator.pop(context);
            Session.i.signOut();
          },
        ),
        const Spacer(),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('BRV POS · BRV Integrated Systems Limited', style: TextStyle(color: C.muted, fontSize: 12)),
        ),
      ]),
    );
  }
}

/// Shown to a cashier when the admin has not set up the device yet.
class NotReadyScreen extends StatelessWidget {
  const NotReadyScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('BRV POS'), actions: [
          IconButton(onPressed: Session.i.signOut, icon: const Icon(Icons.logout_rounded)),
        ]),
        body: const EmptyNote(Icons.settings_suggest_rounded, 'The admin needs to set up the eTIMS device in Settings before selling.'),
      );
}
