import 'package:flutter/material.dart';
import '../db.dart';
import '../docs.dart';
import '../fmt.dart';
import '../master.dart';
import '../printer.dart';
import '../session.dart';
import '../ui.dart';
import 'track.dart';

/// Clerk's day: bookings and money by payment method, printed for the cash hand-over.
class DayScreen extends StatefulWidget {
  const DayScreen({super.key});
  @override
  State<DayScreen> createState() => _DayScreenState();
}

class _DayScreenState extends State<DayScreen> {
  DateTime _day = DateTime.now();
  bool _all = false;
  List<Map<String, dynamic>> _list = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final a = odooTime(DateTime(_day.year, _day.month, _day.day));
    final b = odooTime(DateTime(_day.year, _day.month, _day.day).add(const Duration(days: 1)));
    _list = _all
        ? await Db.waybills('booked_at >= ? AND booked_at < ? AND origin = ?', [a, b, Master.i.hubId], 'booked_at', 2000)
        : await Db.waybills('booked_at >= ? AND booked_at < ? AND booked_by = ?', [a, b, Session.i.id], 'booked_at', 2000);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final live = _list.where((w) => w['state'] != 'cancelled').toList();
    final by = <String, double>{};
    for (final w in live) {
      by[s(w['payment_mode'])] = (by[s(w['payment_mode'])] ?? 0) + d(w['total']);
    }
    final total = live.fold<double>(0, (a, w) => a + d(w['total']));
    return Scaffold(
      appBar: AppBar(title: Text(_all ? 'Branch day' : 'My day'), actions: [
        IconButton(
          onPressed: () async {
            final p = await showDatePicker(context: context, initialDate: _day, firstDate: DateTime(2024), lastDate: DateTime.now());
            if (p != null) {
              _day = p;
              _load();
            }
          },
          icon: const Icon(Icons.calendar_month),
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        if (Session.i.isSupervisor)
          SwitchListTile(contentPadding: EdgeInsets.zero, value: _all, onChanged: (v) {
            _all = v;
            _load();
          }, title: const Text('Whole branch (all clerks)')),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: box(color: C.ink, border: false),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(dt(_day, time: false), style: const TextStyle(color: Color(0xFFCBD5E1), fontWeight: FontWeight.w700)),
            Text(money(total), style: h(30, color: Colors.white)),
            Text('${live.length} waybills · cash ${money(by['cash'] ?? 0)}', style: const TextStyle(color: Colors.white)),
          ]),
        ),
        const SizedBox(height: 10),
        for (final k in by.keys) ListTile(dense: true, title: Text(payLabels[k] ?? k), trailing: Text(money(by[k]!), style: h(15))),
        const SizedBox(height: 6),
        FilledButton.icon(
          onPressed: () => Printer.print(Docs.day(_list, _all ? '${Master.i.hubName} (all)' : Session.i.name, _day), 'Day summary'),
          icon: const Icon(Icons.print),
          label: const Text('Print day summary'),
        ),
        const Label('Waybills'),
        if (_list.isEmpty) const Empty(Icons.inbox_outlined, 'No bookings this day.'),
        for (final w in _list.reversed)
          ListTile(
            dense: true,
            title: Text('${w['name']} → ${Master.i.hubCodeOf(n(w['destination_hub_id']))}', style: TextStyle(fontWeight: FontWeight.w700, decoration: w['state'] == 'cancelled' ? TextDecoration.lineThrough : null)),
            subtitle: Text('${dtOdoo(s(w['booked_at']))} · ${payLabels[w['payment_mode']] ?? w['payment_mode']}'),
            trailing: Text(money(d(w['total']), symbol: false), style: h(14)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => WaybillPage(w: w))),
          ),
      ]),
    );
  }
}
