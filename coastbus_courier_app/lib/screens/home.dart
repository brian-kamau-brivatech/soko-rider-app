import 'package:flutter/material.dart';
import '../db.dart';
import '../fmt.dart';
import '../master.dart';
import '../session.dart';
import '../sync.dart';
import '../ui.dart';
import 'book.dart';
import 'collect.dart';
import 'day.dart';
import 'load.dart';
import 'offload.dart';
import 'problems.dart';
import 'settings.dart';
import 'track.dart';

class SyncChip extends StatelessWidget {
  const SyncChip({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Sync.i,
      builder: (context, _) {
        final sy = Sync.i;
        final (icon, color, text) = sy.busy
            ? (Icons.sync, Colors.white, 'Syncing')
            : sy.failed > 0
                ? (Icons.error_outline, const Color(0xFFFCA5A5), '${sy.failed} problem${sy.failed == 1 ? '' : 's'}')
                : !sy.online
                    ? (Icons.cloud_off, const Color(0xFFFCD34D), sy.pending > 0 ? 'Offline · ${sy.pending} to send' : 'Offline')
                    : (Icons.cloud_done_outlined, const Color(0xFF86EFAC), sy.pending > 0 ? '${sy.pending} to send' : 'Up to date');
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: color),
            onPressed: () {
              if (sy.failed > 0 && Session.i.signedIn) {
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProblemsScreen()));
              } else {
                sy.run(full: true);
              }
            },
            icon: Icon(icon, size: 18),
            label: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
          ),
        );
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _waiting = 0, _inbound = 0, _today = 0;
  double _todayTotal = 0;
  int _seen = -1;

  Future<void> _load() async {
    final hub = Master.i.hubId;
    _waiting = await Db.count("SELECT COUNT(*) FROM waybills WHERE state = 'arrived' AND dest = ?", [hub]);
    final inb = await Db.manifests("state = 'in_transit'");
    _inbound = inb.where((m) => m['received_at_$hub'] == null && (n(m['destination_hub_id']) == hub ||
        ((m['lines'] as List?) ?? const []).any((l) => n((l as Map)['destination_hub_id']) == hub))).length;
    final start = odooTime(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day));
    final mine = await Db.waybills("booked_at >= ? AND booked_by = ? AND state != 'cancelled'", [start, Session.i.id]);
    _today = mine.length;
    _todayTotal = mine.fold(0.0, (a, w) => a + d(w['total']));
    if (mounted) setState(() {});
  }

  void _open(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)).then((_) => _load());

  @override
  Widget build(BuildContext context) {
    final ses = Session.i;
    return ListenableBuilder(
      listenable: Sync.i,
      builder: (context, _) {
        if (_seen != Sync.i.version) {
          _seen = Sync.i.version;
          _load();
        }
        final tiles = <(IconData, String, String, Widget, Color)>[
          if (ses.canBook) (Icons.add_box_outlined, 'Book parcel', 'Intake, bill, receipt, labels', const BookScreen(), C.ink),
          if (ses.canLoad) (Icons.local_shipping_outlined, 'Load vehicle', 'Scan parcels onto a trip', const LoadScreen(), C.ink2),
          if (ses.canLoad || ses.canCollect) (Icons.move_to_inbox_outlined, 'Offload vehicle', _inbound > 0 ? '$_inbound vehicle${_inbound == 1 ? '' : 's'} expected' : 'Scan off & tally',
              const OffloadScreen(), const Color(0xFF8A5A00)),
          if (ses.canCollect) (Icons.how_to_reg_outlined, 'Collect parcel', _waiting > 0 ? '$_waiting waiting here' : 'Release to the receiver', const CollectScreen(), C.green),
          (Icons.travel_explore, 'Track parcel', 'Status & custody history', const TrackScreen(), const Color(0xFF475569)),
          if (ses.canBook) (Icons.receipt_long_outlined, 'My day', '$_today booked · ${money(_todayTotal)}', const DayScreen(), const Color(0xFF6D28D9)),
          if (ses.isSupervisor || Sync.i.failed > 0) (Icons.report_problem_outlined, 'Sync problems', '${Sync.i.failed} to check', const ProblemsScreen(), C.red),
          (Icons.settings_outlined, 'Settings', 'Printer, terminal', const SettingsScreen(), const Color(0xFF334155)),
        ];
        return Scaffold(
          appBar: AppBar(
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Master.i.hubName),
              Text(ses.name, style: const TextStyle(fontSize: 12.5, color: Color(0xFFCBD5E1), fontWeight: FontWeight.w600)),
            ]),
            actions: [const SyncChip(), IconButton(tooltip: 'Lock', onPressed: Session.i.lock, icon: const Icon(Icons.lock_outline))],
          ),
          body: RefreshIndicator(
            onRefresh: () => Sync.i.run(full: true),
            child: ListView(padding: const EdgeInsets.all(14), children: [
              GridView.count(
                crossAxisCount: MediaQuery.of(context).size.width > 520 ? 3 : 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.15,
                children: [
                  for (final t in tiles)
                    InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => _open(t.$4),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: box(),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(color: t.$5, borderRadius: BorderRadius.circular(12)),
                            child: Icon(t.$1, color: Colors.white, size: 26),
                          ),
                          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(t.$2, style: h(16)),
                            Text(t.$3, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12.5)),
                          ]),
                        ]),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                Sync.i.lastOk == null ? 'Not synced yet. ${Sync.i.error}' : 'Last sync ${dt(Sync.i.lastOk)}${Sync.i.error.isNotEmpty ? ' · ${Sync.i.error}' : ''}',
                style: const TextStyle(color: C.muted, fontSize: 12.5),
                textAlign: TextAlign.center,
              ),
            ]),
          ),
        );
      },
    );
  }
}
