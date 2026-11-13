import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'receipt_screen.dart';
import 'shell.dart';

/// Sales of this Point of Sale: this shift, today, yesterday, 7 days, this month.
class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});
  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  static const _periods = [('shift', 'This shift'), ('today', 'Today'), ('yesterday', 'Yesterday'), ('week', '7 days'), ('month', 'Month')];
  String _period = 'shift';
  SalesReport? _r;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    posTab.addListener(_onTab);
  }

  @override
  void dispose() {
    posTab.removeListener(_onTab);
    super.dispose();
  }

  void _onTab() {
    if (posTab.value == 1) _load();
  }

  Future<void> _load() async {
    final p = _period;
    try {
      final r = SalesReport.fromJson(await Api.call('/utange/pos/sales', Store.i.base({'period': p})));
      if (mounted && p == _period) {
        setState(() {
          _r = r;
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: C.green,
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
          Text('Sales', style: h(22)),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final p in _periods)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(p.$2),
                    selected: _period == p.$1,
                    onSelected: (_) {
                      setState(() {
                        _period = p.$1;
                        _r = null;
                      });
                      _load();
                    },
                    selectedColor: C.navy,
                    showCheckmark: false,
                    labelStyle: h(13.5, w: FontWeight.w700, color: _period == p.$1 ? Colors.white : C.ink),
                    backgroundColor: Colors.white,
                    side: BorderSide(color: _period == p.$1 ? C.navy : C.line),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          if (r == null && _error == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: C.green)))
          else if (r == null)
            EmptyNote(Icons.wifi_off_rounded, _error!)
          else ...salesBody(context, r, onOpen: (s) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceiptScreen(sale: s)))),
        ]),
      ),
    );
  }
}

/// Totals, payment methods, cashiers, top items and the sales list (also used by the manager app).
List<Widget> salesBody(BuildContext context, SalesReport r, {void Function(Sale)? onOpen}) {
  Widget section(String title, List<Widget> rows) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: h(16)), const SizedBox(height: 6), ...rows]),
      );
  Widget row(String a, String mid, String b) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(a, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (mid.isNotEmpty) Text(mid, style: const TextStyle(color: C.muted, fontSize: 12.5)),
          const SizedBox(width: 12),
          SizedBox(width: 96, child: Text(b, textAlign: TextAlign.right, style: h(13.5))),
        ]),
      );
  return [
    Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: C.navy, borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.from == r.to ? r.from : '${r.from} – ${r.to}', style: const TextStyle(color: Color(0xFFC9D3E0))),
              Text(ksh(r.total), style: h(28, color: Colors.white)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${r.count}', style: h(24, color: Colors.white)),
            const Text('sales', style: TextStyle(color: Color(0xFFC9D3E0))),
          ]),
        ]),
        if (r.byMethod.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final m in r.byMethod)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: const Color(0xFF1E4466), borderRadius: BorderRadius.circular(999)),
                child: Text('${m.name} ${ksh(m.amount)}', style: h(12.5, color: Colors.white)),
              ),
          ]),
        ],
      ]),
    ),
    if (r.byCashier.isNotEmpty) section('By cashier', [for (final c in r.byCashier) row(c.name, '${c.count} sales', ksh(c.amount))]),
    if (r.days.isNotEmpty) section('By day', [for (final d in r.days) row(d.name, '${d.count} sales', ksh(d.amount))]),
    if (r.topProducts.isNotEmpty) section('Top items', [for (final p in r.topProducts) row(p.name, '${qty(p.qty)} sold', ksh(p.amount))]),
    const SizedBox(height: 14),
    Text('Sales · ${r.count}', style: h(16)),
    const SizedBox(height: 8),
    if (r.orders.isEmpty) const EmptyNote(Icons.receipt_long_outlined, 'No sales yet.'),
    for (final s in r.orders)
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: C.line)),
            title: Text('${s.name} · ${r.from == r.to ? s.time : s.date}', style: h(14, w: FontWeight.w700)),
            subtitle: Text([if (s.cashier.isNotEmpty) s.cashier, '${s.count} items', if (s.methods.isNotEmpty) s.methods,
              if (s.customer.isNotEmpty) s.customer].join(' · ')),
            trailing: Text(ksh(s.amount), style: h(15)),
            onTap: onOpen == null ? null : () => onOpen(s),
          ),
        ),
      ),
  ];
}
