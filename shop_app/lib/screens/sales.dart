import 'dart:async';
import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'receipt_screen.dart';
import 'shell.dart';

/// Every POS sale of the day as it happens (POS screen and this app), live.
class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});
  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  int _daysAgo = 0;
  SalesDay? _day;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // Refresh while this tab is showing.
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (tab.value == 3) _load();
    });
    tab.addListener(_onTab);
  }

  void _onTab() {
    if (tab.value == 3) _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    tab.removeListener(_onTab);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await PosApi.sales(Store.i.pin, daysAgo: _daysAgo);
      if (mounted) setState(() {
        _day = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _day;
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: C.green,
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
          Row(children: [
            Expanded(child: Text('Sales', style: h(22))),
            SegmentedButton<int>(
              segments: const [ButtonSegment(value: 0, label: Text('Today')), ButtonSegment(value: 1, label: Text('Yesterday'))],
              selected: {_daysAgo},
              showSelectedIcon: false,
              onSelectionChanged: (v) {
                setState(() {
                  _daysAgo = v.first;
                  _day = null;
                });
                _load();
              },
            ),
          ]),
          const SizedBox(height: 12),
          if (d == null && _error == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: C.green)))
          else if (d == null)
            EmptyNote(Icons.wifi_off_rounded, _error!)
          else ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: C.navy, borderRadius: BorderRadius.circular(18)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Total sales', style: TextStyle(color: Color(0xFFC9D3E0))),
                      Text(ksh(d.total), style: h(28, color: Colors.white)),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('${d.count}', style: h(24, color: Colors.white)),
                    const Text('orders', style: TextStyle(color: Color(0xFFC9D3E0))),
                  ]),
                ]),
                if (d.byMethod.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 6, children: [
                    for (final m in d.byMethod)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: const Color(0xFF16345A), borderRadius: BorderRadius.circular(999)),
                        child: Text('${m.method} ${ksh(m.amount)}', style: h(12.5, color: Colors.white)),
                      ),
                  ]),
                ],
              ]),
            ),
            const SizedBox(height: 12),
            if (d.orders.isEmpty)
              const EmptyNote(Icons.receipt_long_outlined, 'No sales yet.')
            else
              for (final s in d.orders)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    child: ListTile(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: C.line)),
                      leading: CircleAvatar(
                        backgroundColor: s.fromApp ? C.greenLight : C.blueLight,
                        child: Icon(s.fromApp ? Icons.phone_android_rounded : Icons.point_of_sale_rounded,
                            color: s.fromApp ? C.green : C.blue, size: 20),
                      ),
                      title: Text('${s.name} · ${s.time}', style: h(14.5, w: FontWeight.w700)),
                      subtitle: Text([
                        '${s.count} items',
                        if (s.methods.isNotEmpty) s.methods,
                        if (s.customer.isNotEmpty) s.customer,
                        if (s.state == 'draft') 'NOT PAID',
                      ].join(' · ')),
                      trailing: Text(ksh(s.amount), style: h(15)),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceiptScreen(sale: s))),
                    ),
                  ),
                ),
          ],
        ]),
      ),
    );
  }
}
