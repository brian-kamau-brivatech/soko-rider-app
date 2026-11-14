import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'count_screen.dart';

/// Open and close the shift (Odoo POS session) with the stock sheet:
/// open = count the stock + opening cash; close = count the stock + counted cash.
class ShiftScreen extends StatefulWidget {
  const ShiftScreen({super.key});
  @override
  State<ShiftScreen> createState() => _ShiftScreenState();
}

class _ShiftScreenState extends State<ShiftScreen> {
  SessionInfo? _info;
  String? _error;
  bool _busy = false;
  final _cash = TextEditingController();
  final _notes = TextEditingController();
  final _moveAmount = TextEditingController();
  final _moveReason = TextEditingController();
  bool _cashIn = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cash.dispose();
    _notes.dispose();
    _moveAmount.dispose();
    _moveReason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await Api.call('/utange/pos/session', Store.i.base());
      final i = SessionInfo.fromJson(Map<String, dynamic>.from(r['info'] as Map));
      if (!mounted) return;
      setState(() {
        _info = i;
        _error = null;
        if (i.canOpen && _cash.text.isEmpty) _cash.text = qty(i.openingSuggestion);
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  double? get _counted => double.tryParse(_cash.text.trim());

  Future<void> _err(ApiError e) async {
    if (mounted) toast(context, e.message);
    await Store.i.handle(e);
  }

  Future<void> _open() async {
    final i = _info!;
    final cash = _counted;
    if (cash == null) {
      toast(context, 'Enter the opening cash in the drawer.');
      return;
    }
    Map<String, dynamic>? counts;
    if (i.requireSheet && i.sheetReady.isEmpty) {
      counts = await Navigator.of(context)
          .push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => const CountScreen(phase: 'open')));
      if (counts == null || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final r = await Api.call('/utange/pos/session_open',
          Store.i.base({'opening_cash': cash, 'notes': _notes.text.trim(), ...?counts}));
      if (!mounted) return;
      setState(() {
        _info = SessionInfo.fromJson(Map<String, dynamic>.from(r['info'] as Map));
        _notes.clear();
        _cash.clear();
      });
      toast(context, ss(r['message']));
    } on ApiError catch (e) {
      await _err(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    final i = _info!;
    final c = i.closing!;
    final counted = _counted;
    if (c.hasCash && counted == null) {
      toast(context, 'Count the cash in the drawer and enter it.');
      return;
    }
    Map<String, dynamic>? counts;
    if (i.countAtClose && !i.closeReady) {
      counts = await Navigator.of(context)
          .push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => const CountScreen(phase: 'close')));
      if (counts == null || !mounted) return;
    }
    final diff = c.hasCash ? counted! - c.cashExpected : 0.0;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Close ${i.sessionName}?'),
        content: Text([
          '${c.orders} orders · ${ksh(c.amount)}',
          if (c.hasCash) 'Cash counted ${ksh(counted!)} (expected ${ksh(c.cashExpected)})',
          if (c.hasCash && diff.abs() > 0.009) 'Cash difference ${diff > 0 ? '+' : ''}${ksh(diff)}',
          '',
          'Odoo posts the shift and moves the stock. Selling stops until a new shift is opened.',
        ].join('\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: C.red),
            child: const Text('Close shift'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await Api.call('/utange/pos/session_close', Store.i.base({
        if (c.hasCash) 'counted_cash': counted,
        'notes': _notes.text.trim(),
        ...?counts,
      }));
      if (!mounted) return;
      final s = Map<String, dynamic>.from(r['summary'] as Map? ?? const {});
      final diffs = ll(s['stock_diffs']);
      _cash.clear();
      _notes.clear();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle_rounded, color: C.green, size: 40),
          title: Text(ss(r['message'])),
          content: SingleChildScrollView(
            child: Text([
              '${ii(s['orders'])} orders · ${ksh(dd(s['amount']))}',
              if (s['cash_counted'] != null) 'Cash counted ${ksh(dd(s['cash_counted']))}',
              if (s['difference'] != null && dd(s['difference']).abs() > 0.009) 'Cash difference ${ksh(dd(s['difference']))}',
              '',
              'Stock sheet ${ss(s['sheet'])}: ${diffs.isEmpty ? 'no differences' : '${diffs.length} differences'}',
              for (final d in diffs.take(12)) '• ${ss(d['name'])}: ${signed(dd(d['diff']))}',
              if (diffs.isNotEmpty) 'Value at selling price: ${ksh(dd(s['stock_variance']))}',
            ].join('\n')),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      await Store.i.clearCashier(); // like closing Odoo POS: the cashier is signed out
    } on ApiError catch (e) {
      await _err(e);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmOpening() async {
    final counts = await Navigator.of(context)
        .push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => const CountScreen(phase: 'open')));
    if (counts == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await Api.call('/utange/pos/sheet_confirm_open', Store.i.base(counts));
      if (!mounted) return;
      setState(() => _info = SessionInfo.fromJson(Map<String, dynamic>.from(r['info'] as Map)));
      toast(context, ss(r['message']));
    } on ApiError catch (e) {
      await _err(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cashMove() async {
    final amount = double.tryParse(_moveAmount.text.trim());
    if (amount == null || amount <= 0 || _moveReason.text.trim().isEmpty) {
      toast(context, 'Enter the amount and a reason.');
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await Api.call('/utange/pos/cash_move',
          Store.i.base({'kind': _cashIn ? 'in' : 'out', 'amount': amount, 'reason': _moveReason.text.trim()}));
      if (!mounted) return;
      setState(() {
        _info = SessionInfo.fromJson(Map<String, dynamic>.from(r['info'] as Map));
        _moveAmount.clear();
        _moveReason.clear();
      });
      toast(context, ss(r['message']));
    } on ApiError catch (e) {
      await _err(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = _info;
    return Scaffold(
      appBar: bar('Shift'),
      body: RefreshIndicator(
        color: C.green,
        onRefresh: _load,
        child: Loader(
          loading: i == null,
          error: _error,
          onRetry: _load,
          child: () {
            final si = i!;
            return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
              _status(si),
              const SizedBox(height: 14),
              if (si.isOpen && si.needsOpenCount)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: C.amberLight, borderRadius: BorderRadius.circular(16)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Confirm the opening stock', style: h(16, color: C.amber)),
                    const SizedBox(height: 4),
                    const Text('This shift was opened in Odoo without a count. Count every item now; selling on the handheld '
                        'starts after this.'),
                    const SizedBox(height: 10),
                    primaryButton('Count opening stock', _confirmOpening, icon: Icons.fact_check_rounded, color: C.amber, busy: _busy),
                  ]),
                ),
              if (si.canOpen) _openCard(si),
              if (si.isOpen && si.canCashMove) _cashMoveCard(),
              if ((si.isOpen || si.isClosing) && si.closing != null) _closeCard(si, si.closing!),
            ]);
          },
        ),
      ),
    );
  }

  Widget _status(SessionInfo i) {
    final open = i.isOpen;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: open ? C.green : C.navy, borderRadius: BorderRadius.circular(18)),
      child: Row(children: [
        Icon(open ? Icons.lock_open_rounded : Icons.lock_rounded, color: Colors.white, size: 34),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(open ? 'Shift open' : i.isClosing ? 'Closing' : 'Shift closed', style: h(22, color: Colors.white)),
            Text(
              open || i.isClosing
                  ? '${i.sessionName} · since ${i.startAt.length >= 16 ? i.startAt.substring(11, 16) : i.startAt}'
                  : (i.lastClosedName.isEmpty ? i.config : 'Last: ${i.lastClosedName} · ${i.lastClosedAt}'),
              style: const TextStyle(color: Color(0xFFE6EEF7)),
            ),
            if (i.sheetName.isNotEmpty)
              Text('Stock sheet ${i.sheetName}${i.openDiffs > 0 ? ' · ${i.openDiffs} opening differences' : ''}',
                  style: const TextStyle(color: Color(0xFFE6EEF7), fontSize: 12.5)),
            if (i.cashierName.isNotEmpty)
              Text('${i.cashierName} (${i.cashierRole == 'manager' ? 'manager' : 'cashier'})',
                  style: const TextStyle(color: Color(0xFFE6EEF7), fontSize: 12.5)),
          ]),
        ),
      ]),
    );
  }

  Widget _openCard(SessionInfo i) => Container(
        padding: const EdgeInsets.all(14),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Open the shift', style: h(17)),
          const SizedBox(height: 4),
          Text(
            i.requireSheet && i.sheetReady.isNotEmpty
                ? 'Opening stock already counted in Odoo (${i.sheetReady}). Enter the cash in the drawer and open.'
                : i.requireSheet
                ? '1. Enter the cash in the drawer.  2. Count every item on the stock sheet.  3. Confirm.'
                : 'Count the cash in the drawer.',
            style: const TextStyle(color: C.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _cash,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: h(22),
            decoration: InputDecoration(labelText: 'Opening cash (last close ${ksh(i.openingSuggestion)})', prefixText: 'KSh '),
          ),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Note (optional)', prefixIcon: Icon(Icons.notes_rounded)),
          ),
          const SizedBox(height: 16),
          primaryButton(i.requireSheet && i.sheetReady.isEmpty ? 'Count stock and open' : 'Open shift', _open,
              icon: i.requireSheet && i.sheetReady.isEmpty ? Icons.fact_check_rounded : Icons.lock_open_rounded, busy: _busy),
        ]),
      );

  Widget _cashMoveCard() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Cash in / out', style: h(17)),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Cash in'), icon: Icon(Icons.south_west_rounded)),
              ButtonSegment(value: false, label: Text('Cash out'), icon: Icon(Icons.north_east_rounded)),
            ],
            selected: {_cashIn},
            onSelectionChanged: (v) => setState(() => _cashIn = v.first),
          ),
          TextField(
            controller: _moveAmount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount', prefixText: 'KSh '),
          ),
          TextField(controller: _moveReason, decoration: const InputDecoration(labelText: 'Reason')),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _cashMove,
            icon: const Icon(Icons.payments_rounded),
            label: const Text('Record'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
        ]),
      );

  Widget _line(String a, String b, {bool bold = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(a, style: TextStyle(color: bold ? C.ink : C.muted, fontWeight: bold ? FontWeight.w700 : null))),
          Text(b, style: h(bold ? 15.5 : 14, w: bold ? FontWeight.w800 : FontWeight.w600, color: color ?? C.ink)),
        ]),
      );

  Widget _closeCard(SessionInfo i, SessionClosing c) {
    final counted = _counted;
    final diff = counted == null ? null : counted - c.cashExpected;
    final tooBig = diff != null && c.maxDifference != null && diff.abs() > c.maxDifference! + 0.001;
    final blocked = !i.canClose || c.drafts.isNotEmpty || tooBig || (c.hasCash && counted == null);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('This shift', style: h(17)),
          const SizedBox(height: 6),
          _line('Orders', '${c.orders}'),
          _line('Total sales', ksh(c.amount), bold: true),
          const Divider(color: C.line),
          for (final m in c.other) _line(m.name, ksh(m.amount)),
          if (c.hasCash) ...[
            const Divider(color: C.line),
            _line('${c.cashName}: opening', ksh(c.cashOpening)),
            _line('${c.cashName}: sales', ksh(c.cashPayments)),
            for (final m in c.cashMoves) _line(m.name, ksh(m.amount)),
            _line('Cash expected in drawer', ksh(c.cashExpected), bold: true),
          ],
        ]),
      ),
      const SizedBox(height: 12),
      if (c.drafts.isNotEmpty)
        _warn('Unpaid POS orders are still open: ${c.drafts.join(', ')}. Pay or cancel them in Odoo POS before closing.', C.red, C.redLight),
      if (!i.canClose)
        _warn('${i.cashierName} is a cashier. Only a POS manager can close the shift: sign in as a manager (More > Switch cashier).',
            C.amber, C.amberLight),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Close the shift', style: h(17)),
          if (i.countAtClose)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(i.closeReady ? 'Closing stock already counted in Odoo.' : 'You will count the stock before the shift closes.',
                  style: const TextStyle(color: C.muted)),
            ),
          if (c.hasCash) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _cash,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: h(22),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Cash counted in the drawer', prefixText: 'KSh '),
            ),
            if (diff != null) ...[
              const SizedBox(height: 6),
              _line('Difference', '${diff > 0 ? '+' : ''}${ksh(diff)}',
                  bold: true, color: diff.abs() < 0.01 ? C.green : (tooBig ? C.red : C.amber)),
              if (tooBig)
                Text('More than the KSh ${qty(c.maxDifference!)} allowed. Recount, or a manager closes in Odoo.',
                    style: const TextStyle(color: C.red, fontSize: 12.5)),
            ],
          ],
          TextField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Closing note (optional)', prefixIcon: Icon(Icons.notes_rounded)),
          ),
          const SizedBox(height: 16),
          primaryButton(i.countAtClose && !i.closeReady ? 'Count stock and close' : 'Close shift', blocked ? null : _close,
              icon: Icons.lock_rounded, color: C.red, busy: _busy),
        ]),
      ),
    ]);
  }

  Widget _warn(String text, Color fg, Color bg) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
      );
}
