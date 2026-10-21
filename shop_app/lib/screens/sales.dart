import 'dart:async';
import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'receipt_screen.dart';
import 'shell.dart';

/// Sales report, live: every paid POS sale (POS screen and this app),
/// split into online orders (website / customer app) and walk-in sales.
class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});
  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  static const _periods = [('today', 'Today'), ('yesterday', 'Yesterday'), ('week', '7 days'), ('month', 'Month')];
  String _period = 'today';
  String? _channel; // null = all, 'online', 'walkin'
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
    final period = _period, channel = _channel;
    try {
      final d = await PosApi.sales(Store.i.pin, period: period, channel: channel);
      if (mounted && period == _period && channel == _channel) {
        setState(() {
          _day = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _set({String? period, String? channel, bool clearChannel = false}) {
    setState(() {
      if (period != null) _period = period;
      if (clearChannel) {
        _channel = null;
      } else if (channel != null) {
        _channel = channel;
      }
      _day = null;
    });
    _load();
  }

  String get _channelLabel => _channel == 'online' ? 'Online orders' : _channel == 'walkin' ? 'Walk-in sales' : 'All sales';

  String _range(SalesDay d) => d.from == d.to ? _date(d.from) : '${_date(d.from)} – ${_date(d.to)}';

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String _date(String iso) {
    final p = iso.split('-');
    if (p.length != 3) return iso;
    final m = int.tryParse(p[1]) ?? 0;
    return '${int.tryParse(p[2]) ?? p[2]} ${m >= 1 && m <= 12 ? _months[m - 1] : p[1]}';
  }

  String _qty(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final d = _day;
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
                    onSelected: (_) => _set(period: p.$1),
                    selectedColor: C.navy,
                    showCheckmark: false,
                    labelStyle: h(13.5, w: FontWeight.w700, color: _period == p.$1 ? Colors.white : C.ink),
                    backgroundColor: Colors.white,
                    side: BorderSide(color: _period == p.$1 ? C.navy : C.line),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('All')),
              ButtonSegment(value: 'online', label: Text('Online'), icon: Icon(Icons.delivery_dining_rounded)),
              ButtonSegment(value: 'walkin', label: Text('Walk-in'), icon: Icon(Icons.storefront_rounded)),
            ],
            selected: {_channel ?? 'all'},
            showSelectedIcon: false,
            onSelectionChanged: (v) => v.first == 'all' ? _set(clearChannel: true) : _set(channel: v.first),
          ),
          const SizedBox(height: 12),
          if (d == null && _error == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: C.green)))
          else if (d == null)
            EmptyNote(Icons.wifi_off_rounded, _error!)
          else ...[
            _totalCard(d),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _channelCard('Online orders', Icons.delivery_dining_rounded, C.green, C.greenLight, d.online, 'online')),
              const SizedBox(width: 10),
              Expanded(child: _channelCard('Walk-in', Icons.storefront_rounded, C.blue, C.blueLight, d.walkin, 'walkin')),
            ]),
            if (d.days.length > 1) ...[
              const SizedBox(height: 14),
              _daysCard(d),
            ],
            if (d.topProducts.isNotEmpty) ...[
              const SizedBox(height: 14),
              _topCard(d),
            ],
            const SizedBox(height: 14),
            Text('$_channelLabel · ${d.count}', style: h(16)),
            const SizedBox(height: 8),
            if (d.orders.isEmpty)
              const EmptyNote(Icons.receipt_long_outlined, 'No sales yet.')
            else
              for (final s in d.orders) _saleTile(s),
          ],
        ]),
      ),
    );
  }

  Widget _totalCard(SalesDay d) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: C.navy, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$_channelLabel · ${_range(d)}', style: const TextStyle(color: Color(0xFFC9D3E0))),
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
      );

  Widget _channelCard(String title, IconData icon, Color fg, Color bg, SalesSummary s, String channel) {
    final selected = _channel == channel;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => selected ? _set(clearChannel: true) : _set(channel: channel),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? fg : C.line, width: selected ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(radius: 14, backgroundColor: bg, child: Icon(icon, size: 16, color: fg)),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: h(13.5, w: FontWeight.w700))),
            ]),
            const SizedBox(height: 8),
            Text(ksh(s.total), style: h(19)),
            Text('${s.count} orders', style: const TextStyle(color: C.muted, fontSize: 12.5)),
            for (final m in s.byMethod.take(3))
              Text('${m.method} ${ksh(m.amount)}', style: const TextStyle(color: C.muted, fontSize: 12)),
          ]),
        ),
      ),
    );
  }

  Widget _daysCard(SalesDay d) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('By day', style: h(16)),
          const SizedBox(height: 6),
          const Row(children: [
            Expanded(flex: 3, child: Text('Day', style: TextStyle(color: C.muted, fontSize: 12))),
            Expanded(flex: 3, child: Text('Online', textAlign: TextAlign.right, style: TextStyle(color: C.muted, fontSize: 12))),
            Expanded(flex: 3, child: Text('Walk-in', textAlign: TextAlign.right, style: TextStyle(color: C.muted, fontSize: 12))),
            Expanded(flex: 3, child: Text('Total', textAlign: TextAlign.right, style: TextStyle(color: C.muted, fontSize: 12))),
          ]),
          const Divider(color: C.line),
          for (final day in d.days)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(flex: 3, child: Text(_date(day.day), style: const TextStyle(fontWeight: FontWeight.w600))),
                Expanded(flex: 3, child: Text(ksh(day.online), textAlign: TextAlign.right, style: const TextStyle(color: C.green, fontSize: 13))),
                Expanded(flex: 3, child: Text(ksh(day.walkin), textAlign: TextAlign.right, style: const TextStyle(color: C.blue, fontSize: 13))),
                Expanded(flex: 3, child: Text(ksh(day.total), textAlign: TextAlign.right, style: h(13.5, w: FontWeight.w800))),
              ]),
            ),
        ]),
      );

  Widget _topCard(SalesDay d) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Top products', style: h(16)),
          const SizedBox(height: 6),
          for (final p in d.topProducts.take(8))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                Text('${_qty(p.qty)} sold', style: const TextStyle(color: C.muted, fontSize: 12.5)),
                const SizedBox(width: 12),
                SizedBox(width: 92, child: Text(ksh(p.total), textAlign: TextAlign.right, style: h(13.5, w: FontWeight.w800))),
              ]),
            ),
        ]),
      );

  Widget _saleTile(Sale s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: C.line)),
            leading: CircleAvatar(
              backgroundColor: s.isOnline ? C.greenLight : C.blueLight,
              child: Icon(s.isOnline ? Icons.delivery_dining_rounded : Icons.storefront_rounded,
                  color: s.isOnline ? C.green : C.blue, size: 20),
            ),
            title: Text('${s.name} · ${_period == 'today' || _period == 'yesterday' ? s.time : s.date.length >= 16 ? '${_date(s.date.substring(0, 10))} ${s.time}' : s.date}',
                style: h(14.5, w: FontWeight.w700)),
            subtitle: Text([
              s.isOnline ? 'Online' : 'Walk-in',
              '${s.count} items',
              if (s.methods.isNotEmpty) s.methods,
              if (s.customer.isNotEmpty) s.customer,
            ].join(' · ')),
            trailing: Text(ksh(s.amount), style: h(15)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceiptScreen(sale: s))),
          ),
        ),
      );
}
