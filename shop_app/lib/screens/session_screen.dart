import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';

/// Open and close the POS session, the same steps as the Odoo POS screen:
/// opening cash count to open; counted cash and Odoo's closing to close.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  SessionInfo? _info;
  String? _error;
  bool _busy = false;
  final _cash = TextEditingController();
  final _notes = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cash.dispose();
    _notes.dispose();
    super.dispose();
  }

  String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  Future<void> _load() async {
    try {
      final i = await SessionApi.info(Store.i.pin);
      if (!mounted) return;
      setState(() {
        _info = i;
        _error = null;
        if (i.canOpen && _cash.text.isEmpty) _cash.text = _n(i.openingSuggestion);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  double? get _counted => double.tryParse(_cash.text.trim());

  Future<void> _open() async {
    final cash = _counted;
    if (cash == null) {
      toast(context, 'Enter the opening cash in the drawer.');
      return;
    }
    setState(() => _busy = true);
    try {
      final (msg, info) = await SessionApi.open(Store.i.pin, openingCash: cash, notes: _notes.text.trim());
      if (!mounted) return;
      setState(() {
        _info = info;
        _cash.clear();
        _notes.clear();
      });
      toast(context, msg);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    final i = _info;
    final c = i?.closing;
    if (i == null || c == null) return;
    final counted = _counted;
    if (c.hasCash && counted == null) {
      toast(context, 'Count the cash in the drawer and enter it.');
      return;
    }
    final diff = c.hasCash ? counted! - c.cashExpected : 0.0;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Close ${i.sessionName}?'),
        content: Text([
          '${c.orders} orders · ${ksh(c.amount)}',
          if (c.hasCash) 'Cash counted ${ksh(counted!)} (expected ${ksh(c.cashExpected)})',
          if (c.hasCash && diff.abs() > 0.009) 'Difference ${diff > 0 ? '+' : ''}${ksh(diff)}',
          '',
          'Odoo posts the session to accounting and moves the stock. Selling stops until a new session is opened.',
        ].join('\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: C.red),
            child: const Text('Close session'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final (msg, summary) =
          await SessionApi.close(Store.i.pin, countedCash: c.hasCash ? counted : null, notes: _notes.text.trim());
      if (!mounted) return;
      _cash.clear();
      _notes.clear();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle_rounded, color: C.green, size: 40),
          title: Text(msg),
          content: Text([
            '${summary['orders'] ?? 0} orders · ${ksh(((summary['amount'] ?? 0) as num).toDouble())}',
            if (summary['cash_counted'] != null) 'Cash counted ${ksh((summary['cash_counted'] as num).toDouble())}',
            if (summary['difference'] != null && ((summary['difference'] as num).abs() > 0.009))
              'Difference ${ksh((summary['difference'] as num).toDouble())}',
          ].join('\n')),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      await _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = _info;
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.white, surfaceTintColor: Colors.white, title: Text('POS session', style: h(18))),
      body: i == null
          ? (_error != null
              ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  EmptyNote(Icons.wifi_off_rounded, _error!),
                  TextButton(onPressed: _load, child: const Text('Try again')),
                ])
              : const Center(child: CircularProgressIndicator(color: C.green)))
          : RefreshIndicator(
              color: C.green,
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
                _statusCard(i),
                const SizedBox(height: 14),
                if (i.canOpen) _openCard(i),
                if ((i.isOpen || i.isClosing) && i.closing != null) _closeCard(i, i.closing!),
              ]),
            ),
    );
  }

  Widget _statusCard(SessionInfo i) {
    final open = i.isOpen;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: open ? C.green : C.navy, borderRadius: BorderRadius.circular(18)),
      child: Row(children: [
        Icon(open ? Icons.lock_open_rounded : Icons.lock_rounded, color: Colors.white, size: 34),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(open ? 'Open' : i.isClosing ? 'Closing' : 'Closed', style: h(24, color: Colors.white)),
            Text(
              open || i.isClosing
                  ? '${i.sessionName} · ${i.config} · since ${i.startAt.length >= 16 ? i.startAt.substring(11, 16) : i.startAt}'
                  : (i.lastClosedName.isEmpty ? i.config : 'Last: ${i.lastClosedName} · ${i.lastClosedAt}'),
              style: const TextStyle(color: Color(0xFFE6EEF7)),
            ),
            Text('POS user: ${i.user}', style: const TextStyle(color: Color(0xFFE6EEF7), fontSize: 12.5)),
          ]),
        ),
      ]),
    );
  }

  Widget _openCard(SessionInfo i) => Container(
        padding: const EdgeInsets.all(14),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Open the day', style: h(17)),
          const SizedBox(height: 4),
          Text('Count the cash in the drawer. Last closing left ${ksh(i.openingSuggestion)}.',
              style: const TextStyle(color: C.muted)),
          const SizedBox(height: 12),
          TextField(
            controller: _cash,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: h(22),
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Opening cash', prefixText: 'KSh '),
          ),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Note (optional)', prefixIcon: Icon(Icons.notes_rounded)),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : _open,
              icon: const Icon(Icons.lock_open_rounded),
              label: Text(_busy ? 'Opening…' : 'Open session', style: h(17, color: Colors.white)),
              style: ElevatedButton.styleFrom(backgroundColor: C.green, foregroundColor: Colors.white),
            ),
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
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Today in this session', style: h(17)),
          const SizedBox(height: 6),
          _line('Orders', '${c.orders}'),
          _line('Total sales', ksh(c.amount), bold: true),
          const Divider(color: C.line),
          for (final m in c.other) _line(m.method, ksh(m.amount)),
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
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: C.redLight, borderRadius: BorderRadius.circular(14)),
          child: Text('Unpaid POS orders are still open: ${c.drafts.join(', ')}. Pay or cancel them in Odoo POS before closing.',
              style: const TextStyle(color: C.red, fontWeight: FontWeight.w600)),
        ),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Close the day', style: h(17)),
          if (c.hasCash) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _cash,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: h(22),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Cash counted in the drawer', prefixText: 'KSh '),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 8, children: [
              ActionChip(
                label: Text('Same as expected (${ksh(c.cashExpected)})'),
                onPressed: () => setState(() => _cash.text = _n(c.cashExpected)),
              ),
            ]),
            if (diff != null) ...[
              const SizedBox(height: 6),
              _line('Difference', '${diff > 0 ? '+' : ''}${ksh(diff)}',
                  bold: true, color: diff.abs() < 0.01 ? C.green : (tooBig ? C.red : C.amber)),
              if (tooBig)
                Text('More than the KSh ${_n(c.maxDifference!)} allowed. Recount, or a manager closes in Odoo.',
                    style: const TextStyle(color: C.red, fontSize: 12.5)),
            ],
          ],
          TextField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Closing note (optional)', prefixIcon: Icon(Icons.notes_rounded)),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _busy || c.drafts.isNotEmpty || tooBig || (c.hasCash && counted == null) ? null : _close,
              icon: const Icon(Icons.lock_rounded),
              label: Text(_busy ? 'Closing…' : 'Close session', style: h(17, color: Colors.white)),
              style: ElevatedButton.styleFrom(
                  backgroundColor: C.red, foregroundColor: Colors.white, disabledBackgroundColor: C.line),
            ),
          ),
        ]),
      ),
    ]);
  }
}
