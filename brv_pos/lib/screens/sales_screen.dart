import 'package:flutter/material.dart';
import '../db.dart';
import '../kra.dart';
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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    salesVersion.addListener(_load);
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
    final (icon, color) = switch (status) {
      'signed' => (credit ? Icons.undo_rounded : Icons.verified_rounded, credit ? C.amber : C.green),
      'pending' => (Icons.hourglass_top_rounded, C.amber),
      _ => (Icons.block_rounded, C.red),
    };
    return ListTile(
      onTap: () => _open(r),
      leading: Icon(icon, color: color),
      title: Text('${r['trd_invc_no']}', style: h(15, w: FontWeight.w700)),
      subtitle: Text([
        if (t != null) '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
        Kra.paymentName('${r['pmt_ty_cd']}'),
        if ('${r['cust_nm'] ?? ''}'.isNotEmpty) '${r['cust_nm']}',
        if (status == 'failed') 'not signed',
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

    return Scaffold(
      appBar: AppBar(title: Text('Sales', style: h(19))),
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
            const SizedBox(height: 14),
          ],
          if (_loading)
            const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
          else if (_rows.isEmpty)
            EmptyNote(Icons.receipt_long_outlined, _q.isEmpty ? 'No sales on this day.' : 'Nothing found.')
          else
            Section(_q.isEmpty ? 'Receipts' : 'Results', [
              for (var i = 0; i < _rows.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _tile(_rows[i]),
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
