import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';

class OrderDetailScreen extends StatefulWidget {
  final int orderId;
  final ShopOrder? preview;
  const OrderDetailScreen({super.key, required this.orderId, this.preview});
  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  ShopOrder? _o;
  String? _error;
  bool _busy = false;
  Timer? _timer;
  Set<int> _packed = {};

  @override
  void initState() {
    super.initState();
    _o = widget.preview;
    _load();
    _loadPacked();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final o = await StaffApi.order(Store.i.pin, widget.orderId);
      if (mounted) setState(() => _o = o);
    } catch (e) {
      if (mounted && _o == null) setState(() => _error = '$e');
    }
  }

  // Pack list ticks are kept on this device only.
  String get _packKey => 'packed_${widget.orderId}';
  Future<void> _loadPacked() async {
    final p = await SharedPreferences.getInstance();
    final l = p.getStringList(_packKey) ?? const [];
    if (mounted) setState(() => _packed = l.map(int.parse).toSet());
  }

  Future<void> _togglePacked(int i) async {
    setState(() => _packed.contains(i) ? _packed.remove(i) : _packed.add(i));
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_packKey, _packed.map((e) => '$e').toList());
  }

  Future<void> _ask({int? riderId}) async {
    setState(() => _busy = true);
    try {
      final msg = await StaffApi.askRider(Store.i.pin, widget.orderId, riderId: riderId);
      if (mounted) toast(context, msg);
      await _load();
      Store.i.refresh();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickRider() async {
    final riders = (Store.i.board?.riders ?? const <Rider>[]).where((r) => !r.isOffline).toList()
      ..sort((a, b) => a.km.compareTo(b.km));
    final picked = await showModalBottomSheet<Rider>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: riders.isEmpty
            ? const EmptyNote(Icons.two_wheeler_outlined, 'No rider is online right now.')
            : ListView(shrinkWrap: true, children: [
                Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Ask a rider', style: h(18))),
                for (final r in riders)
                  ListTile(
                    enabled: r.isFree,
                    leading: CircleAvatar(
                      backgroundColor: r.isFree ? C.green : C.line,
                      child: Text(r.name.isEmpty ? '?' : r.name[0].toUpperCase(), style: h(15, color: Colors.white)),
                    ),
                    title: Text(r.name, style: h(15, w: FontWeight.w700)),
                    subtitle: Text(r.isFree
                        ? 'Free · ${r.km.toStringAsFixed(1)} km from shop'
                        : 'On delivery${r.order.isEmpty ? '' : ' · ${r.order}'}'),
                    onTap: r.isFree ? () => Navigator.pop(ctx, r) : null,
                  ),
                const SizedBox(height: 10),
              ]),
      ),
    );
    if (picked != null) _ask(riderId: picked.id);
  }

  @override
  Widget build(BuildContext context) {
    final o = _o;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(o?.trackingNo ?? 'Order', style: h(18)),
        actions: [if (o != null) Padding(padding: const EdgeInsets.only(right: 12), child: StatusChip(o))],
      ),
      body: o == null
          ? (_error != null ? EmptyNote(Icons.error_outline, _error!) : const Center(child: CircularProgressIndicator(color: C.green)))
          : RefreshIndicator(
              color: C.green,
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
                Text('${o.soName}${o.source.isEmpty ? '' : ' · ${o.source}'} · received ${o.ago}',
                    style: const TextStyle(color: C.muted, fontSize: 13)),
                const SizedBox(height: 12),
                _Steps(o),
                const SizedBox(height: 14),
                _riderCard(o),
                const SizedBox(height: 12),
                _packList(o),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: card(),
                  child: Column(children: [
                    _row('Customer', o.customer.isEmpty ? '—' : o.customer),
                    _row('Address', o.address.isEmpty ? '—' : o.address),
                    _row('Delivery fee', '${ksh(o.fee)}${o.km > 0 ? ' · ${o.km.toStringAsFixed(1)} km' : ''}'),
                    const Divider(color: C.line),
                    Row(children: [
                      Expanded(child: Text('Total · ${o.paid ? 'paid M-Pesa' : 'NOT PAID'}', style: h(15, color: o.paid ? C.ink : C.red))),
                      Text(ksh(o.amount), style: h(17)),
                    ]),
                  ]),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: C.blueLight, borderRadius: BorderRadius.circular(14)),
                  child: const Row(children: [
                    Icon(Icons.point_of_sale_rounded, color: C.blue),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text('Checkout and Send to Dispatch stay in Odoo POS.',
                          style: TextStyle(color: C.blue, fontWeight: FontWeight.w600)),
                    ),
                  ]),
                ),
              ]),
            ),
    );
  }

  Widget _riderCard(ShopOrder o) {
    if (o.rider.isNotEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: card(),
        child: Row(children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: C.navy,
            child: Text(o.rider.length >= 2 ? o.rider.substring(0, 2).toUpperCase() : o.rider, style: h(15, color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${o.rider}${o.riderAtShop ? ' · at the shop' : ''}', style: h(15.5)),
              Text(o.riderLine, style: const TextStyle(color: C.muted, fontSize: 13)),
            ]),
          ),
          if (o.riderPhone.isNotEmpty)
            IconButton.filled(
              tooltip: 'Call rider',
              onPressed: () => callNumber(context, o.riderPhone),
              style: IconButton.styleFrom(backgroundColor: C.green),
              icon: const Icon(Icons.phone_rounded, color: Colors.white),
            ),
        ]),
      );
    }
    final canAsk = !o.isDone && o.asking.isEmpty;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: o.noRider ? C.redLight : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: o.noRider ? const Color(0xFFFCA5A5) : C.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(o.riderLine, style: h(15, color: o.noRider ? C.red : C.ink)),
        if (canAsk) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _busy ? null : () => _ask(),
                icon: const Icon(Icons.near_me_rounded),
                label: const Text('Nearest free rider'),
                style: ElevatedButton.styleFrom(backgroundColor: C.green, foregroundColor: Colors.white, minimumSize: const Size(0, 46)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _pickRider,
                icon: const Icon(Icons.person_search_rounded),
                label: const Text('Choose rider'),
                style: OutlinedButton.styleFrom(foregroundColor: C.navy, minimumSize: const Size(0, 46)),
              ),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _packList(ShopOrder o) {
    final lines = o.lines;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Pack list', style: h(16))),
          Text('${_packed.length} of ${lines.length} packed', style: const TextStyle(color: C.muted, fontSize: 13)),
        ]),
        const SizedBox(height: 4),
        if (lines.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Loading items…', style: TextStyle(color: C.muted)))
        else
          for (var i = 0; i < lines.length; i++)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: C.green,
              value: _packed.contains(i),
              onChanged: (_) => _togglePacked(i),
              title: Text('${_qty(lines[i].qty)} × ${lines[i].name}${lines[i].uom.isEmpty || lines[i].uom == 'Units' ? '' : ' (${lines[i].uom})'}',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    decoration: _packed.contains(i) ? TextDecoration.lineThrough : null,
                    color: _packed.contains(i) ? C.muted : C.ink,
                  )),
              secondary: Text(ksh(lines[i].total), style: h(13.5, w: FontWeight.w700)),
            ),
      ]),
    );
  }

  String _qty(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(1);

  Widget _row(String a, String b) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 104, child: Text(a, style: const TextStyle(color: C.muted))),
          Expanded(child: Text(b, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}

class _Steps extends StatelessWidget {
  final ShopOrder o;
  const _Steps(this.o);
  @override
  Widget build(BuildContext context) {
    final step = o.isDone ? 4 : o.isOut ? 3 : o.isPreparing ? 2 : o.rider.isNotEmpty ? 1 : (o.paid ? 0 : -1);
    const labels = ['Paid', 'Rider', 'Preparing', 'Out', 'Delivered'];
    return Row(children: [
      for (var i = 0; i < labels.length; i++)
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < labels.length - 1 ? 4 : 0),
            child: Column(children: [
              Container(
                height: 6,
                decoration: BoxDecoration(
                  color: i < step ? C.green : (i == step ? const Color(0xFF7BD66A) : C.line),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(height: 5),
              Text(labels[i],
                  style: TextStyle(fontSize: 11, fontWeight: i == step ? FontWeight.w800 : FontWeight.w500, color: i == step ? C.ink : C.muted)),
            ]),
          ),
        ),
    ]);
  }
}
