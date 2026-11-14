import 'package:flutter/material.dart';
import '../bus.dart';
import '../db.dart';
import '../fmt.dart';
import '../perms.dart';
import '../session.dart';
import '../ui.dart';
import 'sales_screen.dart';
import 'shell.dart';
import 'shift_screen.dart';
import 'stock_screen.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) => Session.i.can(P.dashboard) ? const AdminDashboard() : const MyDay();
}

/// Period: start, end, previous start, bucket labels and bucket of a date.
class _Range {
  final DateTime start, end, prevStart;
  final List<String> labels;
  final int Function(DateTime) bucket;
  _Range(this.start, this.end, this.prevStart, this.labels, this.bucket);

  static _Range of(String p) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (p == 'today') {
      return _Range(today, today.add(const Duration(days: 1)), today.subtract(const Duration(days: 1)),
          [for (var h = 0; h < 24; h += 2) '${h}h'], (t) => t.hour ~/ 2);
    }
    final days = p == 'week' ? 7 : 30;
    final start = today.subtract(Duration(days: days - 1));
    return _Range(start, today.add(const Duration(days: 1)), start.subtract(Duration(days: days)), [
      for (var k = 0; k < days; k++)
        p == 'week' ? weekdays[start.add(Duration(days: k)).weekday - 1] : '${start.add(Duration(days: k)).day}'
    ], (t) => DateTime(t.year, t.month, t.day).difference(start).inDays);
  }
}

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});
  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  String _period = 'today';
  String _chartPeriod = 'week';
  String _itemsPeriod = 'week';
  Map<String, Object?>? _d;

  @override
  void initState() {
    super.initState();
    dataSettled.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataSettled.removeListener(_load);
    super.dispose();
  }

  Future<Map<String, double>> _totals(DateTime a, DateTime b) async {
    final r = await Db.one(
        'SELECT COUNT(CASE WHEN kind = \'sale\' THEN 1 END) c, COALESCE(SUM(total),0) t, COALESCE(SUM(net - cost),0) gp, '
        'COALESCE(SUM(tax),0) x FROM sales WHERE date >= ? AND date < ?',
        [a.toIso8601String(), b.toIso8601String()]);
    final c = d(r?['c']), t = d(r?['t']);
    return {'count': c, 'total': t, 'profit': d(r?['gp']), 'tax': d(r?['x']), 'avg': c > 0 ? t / c : 0.0};
  }

  Future<void> _load() async {
    final r = _Range.of(_period);
    final cur = await _totals(r.start, r.end);
    final prev = await _totals(r.prevStart, r.start);

    final cr = _Range.of(_chartPeriod);
    final curSeries = List<double>.filled(cr.labels.length, 0);
    final prevSeries = List<double>.filled(cr.labels.length, 0);
    final orders = List<double>.filled(cr.labels.length, 0);
    for (final s0 in await Db.q('SELECT date, total, kind FROM sales WHERE date >= ? AND date < ?',
        [cr.prevStart.toIso8601String(), cr.end.toIso8601String()])) {
      final t = DateTime.tryParse(s(s0['date']));
      if (t == null) continue;
      if (!t.isBefore(cr.start)) {
        final b = cr.bucket(t);
        if (b >= 0 && b < curSeries.length) {
          curSeries[b] += d(s0['total']);
          if (s(s0['kind']) == 'sale') orders[b] += 1;
        }
      } else {
        final shifted = t.add(cr.start.difference(cr.prevStart));
        final b = cr.bucket(shifted);
        if (b >= 0 && b < prevSeries.length) prevSeries[b] += d(s0['total']);
      }
    }

    final ir = _Range.of(_itemsPeriod);
    Future<Map<int, Map<String, Object?>>> items(DateTime a, DateTime b) async => {
          for (final x in await Db.q(
              'SELECT l.product_id, l.name, SUM(l.qty) q, SUM(l.total) t FROM sale_lines l JOIN sales s ON s.id = l.sale_id '
              'WHERE s.date >= ? AND s.date < ? GROUP BY l.product_id ORDER BY q DESC',
              [a.toIso8601String(), b.toIso8601String()]))
            n(x['product_id']): x
        };
    final itNow = await items(ir.start, ir.end);
    final itPrev = await items(ir.prevStart, ir.start);
    final trending = itNow.values.take(6).map((x) {
      final before = d(itPrev[n(x['product_id'])]?['q']);
      final change = before > 0 ? (d(x['q']) - before) / before * 100 : (d(x['q']) > 0 ? 100.0 : 0.0);
      return {...x, 'change': change};
    }).toList();

    final recent = await Db.q(
        'SELECT s.id, s.number, s.date, s.total, s.kind, s.state, u.name AS cashier, c.name AS customer FROM sales s '
        'LEFT JOIN users u ON u.id = s.user_id LEFT JOIN customers c ON c.id = s.customer_id ORDER BY s.id DESC LIMIT 6');
    final byUser = await Db.q(
        'SELECT u.name, COUNT(CASE WHEN s.kind = \'sale\' THEN 1 END) c, SUM(s.total) t FROM sales s JOIN users u ON u.id = s.user_id '
        'WHERE s.date >= ? AND s.date < ? GROUP BY s.user_id ORDER BY t DESC',
        [r.start.toIso8601String(), r.end.toIso8601String()]);
    final byMethod = await Db.q(
        'SELECT m.name, SUM(sp.amount) a FROM sale_payments sp JOIN sales s ON s.id = sp.sale_id JOIN pay_methods m ON m.id = sp.method_id '
        'WHERE s.date >= ? AND s.date < ? GROUP BY m.id ORDER BY a DESC',
        [r.start.toIso8601String(), r.end.toIso8601String()]);
    final low = await Db.count(
        'SELECT COUNT(*) FROM products p WHERE p.active = 1 AND p.track = 1 AND '
        '(SELECT COALESCE(SUM(qty),0) FROM stock WHERE product_id = p.id) <= p.reorder');
    final pendingReq = await Db.count("SELECT COUNT(*) FROM requisitions WHERE state = 'pending'");
    final openShifts = await Db.q(
        "SELECT sh.*, u.name AS user FROM shifts sh JOIN users u ON u.id = sh.user_id WHERE sh.state = 'open' ORDER BY sh.id");
    final stockValue = await Db.sum('SELECT COALESCE(SUM(s.qty * p.cost),0) FROM stock s JOIN products p ON p.id = s.product_id WHERE s.qty > 0');
    if (!mounted) return;
    setState(() => _d = {
          'cur': cur, 'prev': prev, 'labels': cr.labels, 'series': curSeries, 'prevSeries': prevSeries, 'orders': orders,
          'trending': trending, 'recent': recent, 'byUser': byUser, 'byMethod': byMethod, 'low': low,
          'pendingReq': pendingReq, 'openShifts': openShifts, 'stockValue': stockValue,
        });
  }

  double _progress(double a, double b) => b <= 0 ? (a > 0 ? 1.0 : 0.0) : (a / b).clamp(0.0, 1.0).toDouble();

  String _vs(double a, double b) {
    if (b <= 0) return a > 0 ? 'new' : '-';
    final p = (a - b) / b * 100;
    return '${p >= 0 ? '+' : ''}${p.toStringAsFixed(0)}% vs before';
  }

  @override
  Widget build(BuildContext context) {
    final dd0 = _d;
    return Scaffold(
      appBar: TopBar('Dashboard', actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))]),
      body: dd0 == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: _body(dd0)),
            ),
    );
  }

  List<Widget> _body(Map<String, Object?> x) {
    final cur = x['cur'] as Map<String, double>, prev = x['prev'] as Map<String, double>;
    final labels = (x['labels'] as List).cast<String>();
    final series = (x['series'] as List).cast<double>();
    final prevSeries = (x['prevSeries'] as List).cast<double>();
    final orders = (x['orders'] as List).cast<double>();
    final trending = (x['trending'] as List).cast<Map<String, Object?>>();
    final recent = (x['recent'] as List).cast<Map<String, Object?>>();
    final byUser = (x['byUser'] as List).cast<Map<String, Object?>>();
    final byMethod = (x['byMethod'] as List).cast<Map<String, Object?>>();
    final openShifts = (x['openShifts'] as List).cast<Map<String, Object?>>();
    final low = x['low'] as int, pendingReq = x['pendingReq'] as int;
    return [
      Row(children: [
        Expanded(child: Text(_period == 'today' ? 'Today' : (_period == 'week' ? 'Last 7 days' : 'Last 30 days'), style: h(16))),
        PeriodSwitch(value: _period, onChanged: (v) {
          setState(() => _period = v);
          _load();
        }),
      ]),
      const SizedBox(height: 12),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.25,
        children: [
          StatTile(dark: true, value: short(cur['total']!), label: 'Total sales (KSh)', progress: _progress(cur['total']!, prev['total']!), note: _vs(cur['total']!, prev['total']!)),
          StatTile(value: short(cur['count']!), label: 'Orders', progress: _progress(cur['count']!, prev['count']!), note: _vs(cur['count']!, prev['count']!), bar: C.lilac),
          StatTile(value: short(cur['avg']!), label: 'Average sale', progress: _progress(cur['avg']!, prev['avg']!), note: _vs(cur['avg']!, prev['avg']!), bar: const Color(0xFFB9C3D3)),
          StatTile(value: short(cur['profit']!), label: 'Gross profit', progress: cur['total']! > 0 ? cur['profit']! / cur['total']! : 0.0, note: 'margin', bar: C.pink),
        ],
      ),
      const SizedBox(height: 16),
      if (low > 0 || pendingReq > 0 || openShifts.isNotEmpty)
        Container(
          decoration: box(),
          margin: const EdgeInsets.only(bottom: 16),
          child: Column(children: [
            if (openShifts.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.lock_open_rounded, color: C.green),
                title: Text('${openShifts.length} session${openShifts.length == 1 ? '' : 's'} open'),
                subtitle: Text(openShifts.map((e) => s(e['user'])).join(', ')),
              ),
            if (low > 0)
              ListTile(
                leading: const Icon(Icons.warning_amber_rounded, color: C.amber),
                title: Text('$low item${low == 1 ? '' : 's'} low on stock'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StockList(lowOnly: true))),
              ),
            if (pendingReq > 0)
              ListTile(
                leading: const Icon(Icons.assignment_late_rounded, color: C.amber),
                title: Text('$pendingReq requisition${pendingReq == 1 ? '' : 's'} waiting for approval'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RequisitionsScreen())),
              ),
          ]),
        ),
      Container(
        decoration: box(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('Revenue', style: h(17))),
            PeriodSwitch(value: _chartPeriod, options: const [('month', 'Monthly'), ('week', 'Weekly'), ('today', 'Today')], onChanged: (v) {
              setState(() => _chartPeriod = v);
              _load();
            }),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const _Dot(C.ink),
            const Text(' This period   ', style: muted),
            const _Dot(C.pink),
            const Text(' Before', style: muted),
            const Spacer(),
            Text(money(series.fold<double>(0, (a, b) => a + b)), style: h(14)),
          ]),
          const SizedBox(height: 10),
          LineChart(labels: labels, a: series, b: prevSeries),
        ]),
      ),
      const SizedBox(height: 16),
      Container(
        decoration: box(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Orders', style: h(17)),
          const SizedBox(height: 10),
          BarChart(labels: labels, a: orders),
        ]),
      ),
      const SizedBox(height: 16),
      Group('Trending items', [
        if (trending.isEmpty) const Empty(Icons.local_mall_outlined, 'No sales in this period.'),
        for (final t in trending)
          ListTile(
            leading: Avatar(s(t['name']), size: 42),
            title: Text(s(t['name']), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${qty(d(t['q']))} sold · ${money(d(t['t']))}'),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(qty(d(t['q'])), style: h(16)),
              Text('${d(t['change']) >= 0 ? '+' : ''}${d(t['change']).toStringAsFixed(0)}%',
                  style: TextStyle(color: d(t['change']) >= 0 ? C.green : C.red, fontSize: 12, fontWeight: FontWeight.w700)),
            ]),
          ),
      ], trailing: PeriodSwitch(value: _itemsPeriod, onChanged: (v) {
        setState(() => _itemsPeriod = v);
        _load();
      })),
      Group('Order list', [
        if (recent.isEmpty) const Empty(Icons.receipt_long_outlined, 'No sales yet.'),
        for (final r0 in recent)
          ListTile(
            leading: Avatar(s(r0['customer']).isNotEmpty ? s(r0['customer']) : s(r0['cashier']), size: 42),
            title: Text(s(r0['customer']).isNotEmpty ? s(r0['customer']) : s(r0['cashier']), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${s(r0['number'])} · ${dateText(r0['date'])}'),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${d(r0['total']) >= 0 ? '+ ' : ''}${money(d(r0['total']))}', style: h(14)),
              const SizedBox(height: 3),
              s(r0['kind']) == 'refund'
                  ? const Pill('Refund', fg: C.red, bg: C.redLight)
                  : (s(r0['state']) == 'refunded' ? const Pill('Refunded', fg: C.amber, bg: C.amberLight) : const Pill('Paid', fg: C.green, bg: C.greenLight)),
            ]),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SaleDetail(saleId: n(r0['id'])))),
          ),
      ], trailing: TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SalesScreen())), child: const Text('All'))),
      Group('Staff', [
        if (byUser.isEmpty) const Empty(Icons.people_outline, 'No sales in this period.'),
        for (final u in byUser)
          ListTile(
            leading: Avatar(s(u['name']), size: 40),
            title: Text(s(u['name'])),
            subtitle: Text('${n(u['c'])} sales'),
            trailing: Text(money(d(u['t'])), style: h(14)),
          ),
      ]),
      Group('Payments', [
        if (byMethod.isEmpty) const Empty(Icons.payments_outlined, 'No payments in this period.'),
        for (final m in byMethod) KV(s(m['name']), money(d(m['a']))),
      ]),
      Group('Stock', [KV('Stock value (at cost)', money(x['stockValue'] as double), bold: true)]),
    ];
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot(this.color);
  @override
  Widget build(BuildContext context) => Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

/// Home for people without the dashboard right: their shift and their sales today.
class MyDay extends StatefulWidget {
  const MyDay({super.key});
  @override
  State<MyDay> createState() => _MyDayState();
}

class _MyDayState extends State<MyDay> {
  Map<String, Object?>? _t;

  @override
  void initState() {
    super.initState();
    dataSettled.addListener(_load);
    Session.i.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataSettled.removeListener(_load);
    Session.i.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final r = await Db.one(
        "SELECT COUNT(CASE WHEN kind='sale' THEN 1 END) c, COALESCE(SUM(total),0) t FROM sales WHERE user_id = ? AND day = ?",
        [Session.i.userId, dayKey(DateTime.now())]);
    if (mounted) setState(() => _t = r);
  }

  @override
  Widget build(BuildContext context) {
    final ses = Session.i;
    final shift = ses.shift;
    return Scaffold(
      appBar: TopBar('Hi, ${ses.name.split(' ').first}'),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        Row(children: [
          Expanded(child: StatTile(dark: true, value: short(d(_t?['t'])), label: 'My sales today (KSh)', progress: 1, note: ses.roleName)),
          const SizedBox(width: 12),
          Expanded(child: StatTile(value: '${n(_t?['c'])}', label: 'My orders today', progress: 1, note: 'today')),
        ]),
        const SizedBox(height: 16),
        if (ses.can(P.shift))
          Container(
            decoration: box(),
            child: ListTile(
              leading: Icon(shift == null ? Icons.lock_outline : Icons.lock_open_rounded, color: shift == null ? C.muted : C.green),
              title: Text(shift == null ? 'No session open' : 'Session ${s(shift['number'])} open'),
              subtitle: Text(shift == null ? 'Open a session to start selling' : 'Since ${dateText(shift['opened_at'])}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShiftScreen())),
            ),
          ),
        const SizedBox(height: 12),
        Container(
          decoration: box(),
          child: ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('My sales'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SalesScreen())),
          ),
        ),
        if (ses.can(P.reqCreate)) ...[
          const SizedBox(height: 12),
          Container(
            decoration: box(),
            child: ListTile(
              leading: const Icon(Icons.move_up_rounded),
              title: const Text('Requisitions'),
              subtitle: const Text('Ask the store for stock'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RequisitionsScreen())),
            ),
          ),
        ],
      ]),
    );
  }
}
