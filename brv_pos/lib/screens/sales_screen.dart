import 'package:flutter/material.dart';
import '../db.dart';
import '../kra.dart';
import '../kra_check.dart';
import '../sales.dart';
import '../ui.dart';
import 'sale_screen.dart';

class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});
  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  DateTime _day = DateTime.now();
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _waiting = [];
  String _q = '';
  String _filter = 'all'; // all | kra | pending | void
  bool _loading = true;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _load();
    salesVersion.addListener(_load);
    Future.microtask(() => _checkKra(quiet: true));
  }

  Future<void> _checkKra({bool quiet = false}) async {
    if (_checking) return;
    setState(() => _checking = true);
    final (ok, n) = await KraCheck.checkRecent();
    if (!mounted) return;
    setState(() => _checking = false);
    if (!quiet) {
      toast(context, n == 0 ? 'Could not reach KRA, or nothing to check.' : 'Checked $n: $ok confirmed at KRA.');
    }
  }

  @override
  void dispose() {
    salesVersion.removeListener(_load);
    super.dispose();
  }

  String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    final db = await Db.get();
    final List<Map<String, Object?>> r;
    if (_q.isEmpty) {
      r = await db.query('sales', where: "day = ? AND status != 'pending'", whereArgs: [_ymd(_day)], orderBy: 'id DESC');
    } else {
      final like = '%$_q%';
      r = await db.query('sales',
          where: "status != 'pending' AND (trd_invc_no LIKE ? OR cust_nm LIKE ? OR cust_tin LIKE ? OR CAST(invc_no AS TEXT) = ?)",
          whereArgs: [like, like, like, _q],
          orderBy: 'id DESC',
          limit: 200);
    }
    final w = await db.query('sales', where: "status = 'pending'", orderBy: 'id');
    if (mounted) {
      setState(() {
        _rows = r.map((e) => Map<String, dynamic>.from(e)).toList();
        _waiting = w.map((e) => Map<String, dynamic>.from(e)).toList();
        _loading = false;
      });
    }
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d != null) {
      setState(() => _day = d);
      _load();
    }
  }

  Future<void> _open(Map<String, dynamic> r) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SaleScreen(saleId: r['id'] as int)));
    _load();
  }

  Widget _tile(Map<String, dynamic> r) {
    final status = '${r['status']}';
    final credit = r['kind'] == 'R';
    final t = DateTime.tryParse('${r['created_at']}');
    final total = (r['tot_amt'] as num?)?.toDouble() ?? 0;
    final atKra = r['kra_ok'] == KraCheck.confirmed;
    final (icon, color, label) = switch (status) {
      'signed' when atKra => (Icons.cloud_done_rounded, C.green, 'At KRA'),
      'signed' => (Icons.cloud_upload_rounded, C.amber, 'Signed · KRA not confirmed'),
      'pending' => (Icons.hourglass_top_rounded, C.amber, 'Waiting for VSCU'),
      _ => (Icons.block_rounded, C.red, 'Not signed'),
    };
    return ListTile(
      onTap: () => _open(r),
      leading: Icon(icon, color: color),
      title: Row(children: [
        Flexible(child: Text('${credit ? 'CN ' : ''}${r['trd_invc_no']}', style: h(15, w: FontWeight.w700), overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 6),
        Pill(label, fg: color, bg: color == C.green ? C.greenLight : (color == C.red ? C.redLight : C.amberLight)),
      ]),
      subtitle: Text([
        if (t != null) '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
        Kra.paymentName('${r['pmt_ty_cd']}'),
        if ('${r['cust_nm'] ?? ''}'.isNotEmpty) '${r['cust_nm']}',
        if ((r['copies'] as int? ?? 0) > 0) '${r['copies']} cop${r['copies'] == 1 ? 'y' : 'ies'}',
      ].join(' · ')),
      trailing: Text(
        '${credit ? '−' : ''}${money(total, symbol: false)}',
        style: h(15, color: status == 'failed' ? C.muted : (credit ? C.amber : C.ink)).copyWith(
          decoration: status == 'failed' ? TextDecoration.lineThrough : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final signed = _rows.where((r) => r['status'] == 'signed');
    double sum(Iterable<Map<String, dynamic>> it) => it.fold<double>(0, (a, r) => a + ((r['tot_amt'] as num?)?.toDouble() ?? 0));
    final salesTotal = sum(signed.where((r) => r['kind'] == 'S'));
    final creditTotal = sum(signed.where((r) => r['kind'] == 'R'));
    final vat = signed.fold<double>(0, (a, r) => a + ((r['tot_tax'] as num?)?.toDouble() ?? 0) * (r['kind'] == 'R' ? -1 : 1));
    final today = _ymd(_day) == _ymd(DateTime.now());
    final atKra = signed.where((r) => r['kra_ok'] == KraCheck.confirmed).length;
    final shown = _rows.where((r) => switch (_filter) {
          'kra' => r['status'] == 'signed' && r['kra_ok'] == KraCheck.confirmed,
          'pending' => r['status'] == 'signed' && r['kra_ok'] != KraCheck.confirmed,
          'void' => r['status'] == 'failed',
          _ => true,
        }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Receipts / Invoices')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 6, 14, 30), children: [
          TextField(
            decoration: field('Find invoice, customer or PIN', prefix: const Icon(Icons.search_rounded)),
            onChanged: (v) {
              _q = v.trim();
              _load();
            },
          ),
          const SizedBox(height: 12),
          if (_waiting.isNotEmpty)
            Section('Waiting for the VSCU', [for (final r in _waiting) _tile(r)]),
          if (_q.isEmpty) ...[
            Row(children: [
              IconButton(
                onPressed: () {
                  setState(() => _day = _day.subtract(const Duration(days: 1)));
                  _load();
                },
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: _pickDay,
                  icon: const Icon(Icons.calendar_today_rounded, size: 18),
                  label: Text(today ? 'Today' : '${_day.day}/${_day.month}/${_day.year}', style: h(16)),
                ),
              ),
              IconButton(
                onPressed: today
                    ? null
                    : () {
                        setState(() => _day = _day.add(const Duration(days: 1)));
                        _load();
                      },
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ]),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: card(),
              child: Row(children: [
                _stat('Sales', money(salesTotal, symbol: false), '${signed.where((r) => r['kind'] == 'S').length} receipts'),
                _stat('Credit notes', money(creditTotal, symbol: false), '${signed.where((r) => r['kind'] == 'R').length}'),
                _stat('VAT', money(vat, symbol: false), 'net'),
              ]),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
              decoration: BoxDecoration(
                color: signed.isEmpty || atKra == signed.length ? C.greenLight : C.amberLight,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(children: [
                Icon(signed.isEmpty || atKra == signed.length ? Icons.cloud_done_rounded : Icons.cloud_sync_rounded,
                    color: signed.isEmpty || atKra == signed.length ? C.green : C.amber),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    signed.isEmpty
                        ? 'No signed sales on this day.'
                        : '$atKra of ${signed.length} confirmed at KRA',
                    style: h(14, w: FontWeight.w700, color: signed.isEmpty || atKra == signed.length ? C.green : C.amber),
                  ),
                ),
                _checking
                    ? const Padding(padding: EdgeInsets.all(10), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                    : TextButton(onPressed: () => _checkKra(), child: const Text('Check now')),
              ]),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final f in const [('all', 'All'), ('kra', 'At KRA'), ('pending', 'Not confirmed'), ('void', 'Not signed')])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.$2),
                      selected: _filter == f.$1,
                      onSelected: (_) => setState(() => _filter = f.$1),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 12),
          ],
          if (_loading)
            const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
          else if (shown.isEmpty)
            EmptyNote(Icons.receipt_long_outlined, _q.isEmpty ? 'No receipts here.' : 'Nothing found.')
          else
            Section(_q.isEmpty ? 'Receipts' : 'Results', [
              for (var i = 0; i < shown.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _tile(shown[i]),
              ],
            ]),
        ]),
      ),
    );
  }

  Widget _stat(String label, String value, String sub) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: h(11, color: C.muted).copyWith(letterSpacing: 0.6)),
          const SizedBox(height: 2),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: h(17))),
          Text(sub, style: const TextStyle(color: C.muted, fontSize: 12)),
        ]),
      );
}
