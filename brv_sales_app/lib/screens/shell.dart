import 'package:flutter/material.dart';
import '../config.dart';
import '../licence.dart';
import '../perms.dart';
import '../session.dart';
import '../ui.dart';
import 'dashboard.dart';
import 'devices_screen.dart';
import 'more_screen.dart';
import 'reports_screen.dart';
import 'sell_screen.dart';
import 'stock_screen.dart';

/// Main screen with the dark bottom bar (like the reference design). Tabs follow the user's rights.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _Tab {
  final String label;
  final IconData icon;
  final IconData active;
  final Widget page;
  const _Tab(this.label, this.icon, this.active, this.page);
}

class _ShellState extends State<Shell> {
  int _i = 0;

  @override
  void initState() {
    super.initState();
    Licence.i.addListener(_redraw);
  }

  @override
  void dispose() {
    Licence.i.removeListener(_redraw);
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  List<_Tab> _tabs() {
    final ses = Session.i;
    return [
      const _Tab('Home', Icons.grid_view_outlined, Icons.grid_view_rounded, HomePage()),
      if (ses.can(P.sell)) const _Tab('Sell', Icons.point_of_sale_outlined, Icons.point_of_sale_rounded, SellScreen()),
      if (ses.can(P.products) || ses.can(P.stockAdjust) || ses.can(P.reqCreate) || ses.can(P.reqApprove) || ses.can(P.purchase) || ses.can(P.purchaseReceive))
        const _Tab('Stock', Icons.inventory_2_outlined, Icons.inventory_2_rounded, StockHome()),
      if (ses.can(P.reports)) const _Tab('Reports', Icons.insights_outlined, Icons.insights_rounded, ReportsScreen()),
      const _Tab('More', Icons.settings_outlined, Icons.settings_rounded, MoreScreen()),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs();
    if (_i >= tabs.length) _i = 0;
    final days = Licence.i.daysLeft;
    return Scaffold(
      body: Column(children: [
        if (days <= 7)
          Container(
            width: double.infinity,
            color: days <= 2 ? C.red : C.amber,
            padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 6, 16, 6),
            child: Text('Licence ends in $days day${days == 1 ? '' : 's'}. ${isManagerApp ? 'Contact BRV Integrated Systems to renew.' : 'Tell your manager.'}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: days <= 7,
            child: IndexedStack(index: _i, children: [for (final t in tabs) t.page]),
          ),
        ),
      ]),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(color: C.ink),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 66,
            child: Row(children: [
              for (var k = 0; k < tabs.length; k++)
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _i = k),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(k == _i ? tabs[k].active : tabs[k].icon, color: k == _i ? Colors.white : const Color(0xFF8C9AB3), size: 24),
                      const SizedBox(height: 4),
                      Text(tabs[k].label,
                          style: TextStyle(color: k == _i ? Colors.white : const Color(0xFF8C9AB3), fontSize: 11.5, fontWeight: k == _i ? FontWeight.w800 : FontWeight.w600)),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Top of each tab: title, user chip (tap to lock / switch user).
class TopBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget> actions;
  const TopBar(this.title, {super.key, this.actions = const []});
  @override
  Size get preferredSize => const Size.fromHeight(64);
  @override
  Widget build(BuildContext context) => AppBar(
        toolbarHeight: 64,
        automaticallyImplyLeading: false,
        title: Text(title, style: h(25)),
        actions: [
          ...actions,
          const SyncChip(),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GestureDetector(
              onTap: () async {
                if (await confirm(context, 'Lock / switch user', '${Session.i.name}, sign out so someone else can use the app?', ok: 'Lock')) {
                  Session.i.lock();
                }
              },
              child: Avatar(Session.i.name, size: 42, bg: C.ink, fg: Colors.white),
            ),
          ),
        ],
      );
}
