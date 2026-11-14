import 'package:flutter/material.dart';
import '../bus.dart';
import '../db.dart';
import '../fmt.dart';
import '../ledger.dart';
import '../ops.dart';
import '../perms.dart';
import '../receipt.dart';
import '../sales.dart' show SaleError;
import '../session.dart';
import '../ui.dart';

/// Period picker shared by statements and reports.
class Period {
  DateTime from;
  DateTime to; // exclusive
  Period(this.from, this.to);

  static Period thisMonth() {
    final n0 = DateTime.now();
    return Period(DateTime(n0.year, n0.month, 1), DateTime(n0.year, n0.month + 1, 1));
  }

  static Period today() {
    final n0 = DateTime.now();
    final t = DateTime(n0.year, n0.month, n0.day);
    return Period(t, t.add(const Duration(days: 1)));
  }

  String get label {
    final last = to.subtract(const Duration(days: 1));
    if (from.year == last.year && from.month == last.month && from.day == 1 && to.day == 1) return '${months[from.month - 1]} ${from.year}';
    return '${dateText(from.toIso8601String(), time: false)} - ${dateText(last.toIso8601String(), time: false)}';
  }

  String get a => from.toIso8601String();
  String get b => to.toIso8601String();
}

class PeriodBar extends StatelessWidget {
  final Period period;
  final VoidCallback onChanged;
  const PeriodBar({super.key, required this.period, required this.onChanged});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final r = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now().add(const Duration(days: 1)),
                  initialDateRange: DateTimeRange(start: period.from, end: period.to.subtract(const Duration(days: 1))),
                );
                if (r != null) {
                  period.from = r.start;
                  period.to = DateTime(r.end.year, r.end.month, r.end.day).add(const Duration(days: 1));
                  onChanged();
                }
              },
              icon: const Icon(Icons.date_range),
              label: Text(period.label),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            icon: const Icon(Icons.tune),
            onSelected: (v) {
              final p = switch (v) { 'today' => Period.today(), 'month' => Period.thisMonth(), _ => _lastMonth() };
              period.from = p.from;
              period.to = p.to;
              onChanged();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'today', child: Text('Today')),
              PopupMenuItem(value: 'month', child: Text('This month')),
              PopupMenuItem(value: 'last', child: Text('Last month')),
            ],
          ),
        ]),
      );

  static Period _lastMonth() {
    final n0 = DateTime.now();
    return Period(DateTime(n0.year, n0.month - 1, 1), DateTime(n0.year, n0.month, 1));
  }
}

class AccountingScreen extends StatelessWidget {
  const AccountingScreen({super.key});
  @override
  Widget build(BuildContext context) {
    void go(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    Widget tile(IconData i, String t, String sub, Widget w) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: box(),
          child: ListTile(leading: CircleAvatar(backgroundColor: C.soft, child: Icon(i, color: C.ink)), title: Text(t, style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: Text(sub), trailing: const Icon(Icons.chevron_right), onTap: () => go(w)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Accounting')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        tile(Icons.trending_up, 'Profit and loss', 'Income, costs and profit for a period', const ProfitLossScreen()),
        tile(Icons.account_balance_outlined, 'Balance sheet', 'What the business owns and owes', const BalanceSheetScreen()),
        tile(Icons.list_alt, 'Accounts', 'Chart of accounts with balances and ledgers', const AccountsScreen()),
        tile(Icons.menu_book_outlined, 'Journal', 'Every entry, newest first', const JournalScreen()),
        tile(Icons.edit_note, 'Manual entry', 'Opening balances, owner money in/out, corrections', const ManualEntry()),
        tile(Icons.receipt_outlined, 'Expenses', 'Rent, salaries, transport...', const ExpensesScreen()),
      ]),
    );
  }
}

class ProfitLossScreen extends StatefulWidget {
  const ProfitLossScreen({super.key});
  @override
  State<ProfitLossScreen> createState() => _ProfitLossScreenState();
}

class _ProfitLossScreenState extends State<ProfitLossScreen> {
  final _p = Period.thisMonth();
  Map<String, Object>? _r;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Ledger.profitAndLoss(_p.a, _p.b);
    if (mounted) setState(() => _r = r);
  }

  List<PLine> _print(Map<String, Object> r) => [
        const PLine.center('PROFIT AND LOSS', size: 22, bold: true),
        PLine.center(_p.label, size: 18),
        const PLine.dash(),
        const PLine.left('Income', bold: true),
        for (final e in (r['income'] as List<(String, double)>)) PLine.row('  ${e.$1}', money(e.$2, symbol: false)),
        PLine.row('Total income', money(r['total_income'] as double, symbol: false), bold: true),
        const PLine.dash(),
        const PLine.left('Costs and expenses', bold: true),
        for (final e in (r['expense'] as List<(String, double)>)) PLine.row('  ${e.$1}', money(e.$2, symbol: false)),
        PLine.row('Total costs', money(r['total_expense'] as double, symbol: false), bold: true),
        const PLine.dash(),
        PLine.row('PROFIT', money(r['profit'] as double, symbol: false), size: 24, bold: true),
      ];

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return Scaffold(
      appBar: AppBar(title: const Text('Profit and loss'), actions: [
        if (r != null) IconButton(onPressed: () => Printer.pdf(_print(r), 'Profit and loss ${_p.label}', share: true), icon: const Icon(Icons.share_outlined)),
        if (r != null) IconButton(onPressed: () => Printer.printLines(_print(r), 'Profit and loss'), icon: const Icon(Icons.print_outlined)),
      ]),
      body: Column(children: [
        PeriodBar(period: _p, onChanged: _load),
        Expanded(
          child: r == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                  Group('Income', [
                    for (final e in (r['income'] as List<(String, double)>)) KV(e.$1, money(e.$2)),
                    KV('Total income', money(r['total_income'] as double), bold: true),
                  ]),
                  Group('Costs and expenses', [
                    for (final e in (r['expense'] as List<(String, double)>)) KV(e.$1, money(e.$2)),
                    KV('Total costs', money(r['total_expense'] as double), bold: true),
                  ]),
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: box(color: C.ink, border: false),
                    child: Row(children: [
                      Text((r['profit'] as double) >= 0 ? 'Profit' : 'Loss', style: h(18, color: Colors.white)),
                      const Spacer(),
                      Text(money(r['profit'] as double), style: h(22, color: C.gold)),
                    ]),
                  ),
                ]),
        ),
      ]),
    );
  }
}

class BalanceSheetScreen extends StatefulWidget {
  const BalanceSheetScreen({super.key});
  @override
  State<BalanceSheetScreen> createState() => _BalanceSheetScreenState();
}

class _BalanceSheetScreenState extends State<BalanceSheetScreen> {
  Map<String, Object>? _r;

  @override
  void initState() {
    super.initState();
    final t = DateTime.now().add(const Duration(days: 1));
    Ledger.balanceSheet(DateTime(t.year, t.month, t.day).toIso8601String()).then((r) {
      if (mounted) setState(() => _r = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return Scaffold(
      appBar: AppBar(title: const Text('Balance sheet')),
      body: r == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Text('As at ${dateText(nowIso(), time: false)}', style: muted),
              const SizedBox(height: 10),
              Group('What the business owns (assets)', [
                for (final e in (r['assets'] as List<(String, double)>)) KV(e.$1, money(e.$2)),
                KV('Total assets', money(r['total_assets'] as double), bold: true),
              ]),
              Group('What it owes (liabilities)', [
                for (final e in (r['liabilities'] as List<(String, double)>)) KV(e.$1, money(e.$2)),
                KV('Total liabilities', money(r['total_liabilities'] as double), bold: true),
              ]),
              Group('Owner\'s equity', [
                for (final e in (r['equity'] as List<(String, double)>)) KV(e.$1, money(e.$2)),
                KV('Total equity', money(r['total_equity'] as double), bold: true),
              ]),
              KV('Liabilities + equity', money((r['total_liabilities'] as double) + (r['total_equity'] as double)), bold: true),
            ]),
    );
  }
}

class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});
  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  List<Map<String, Object?>> _rows = [];
  Map<int, double> _bal = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final a = await Ledger.accounts();
    final b = await Ledger.balances();
    if (mounted) setState(() { _rows = a; _bal = b; });
  }

  Future<void> _add() async {
    final name = await ask(context, 'New expense account', label: 'e.g. Security, Packaging');
    if (name == null || name.trim().isEmpty) return;
    final db = await Db.get();
    final next = await Db.count("SELECT COALESCE(MAX(CAST(code AS INTEGER)), 6000) + 10 FROM accounts WHERE type = 'expense' AND code LIKE '6%'");
    await Db.ins(db, 'accounts', {'code': '$next', 'name': name.trim(), 'type': 'expense'});
    _load();
  }

  static const _types = {'asset': 'Assets', 'liability': 'Liabilities', 'equity': 'Equity', 'income': 'Income', 'expense': 'Expenses'};

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Accounts')),
        floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 90), children: [
          for (final t in _types.entries)
            Group(t.value, [
              for (final a in _rows.where((x) => s(x['type']) == t.key))
                ListTile(
                  dense: true,
                  title: Text('${s(a['code'])}  ${s(a['name'])}'),
                  trailing: Text(money(((t.key == 'asset' || t.key == 'expense') ? 1 : -1) * (_bal[n(a['id'])] ?? 0)), style: h(13.5)),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => JournalScreen(accountId: n(a['id']), title: s(a['name'])))),
                ),
            ]),
        ]),
      );
}

class JournalScreen extends StatefulWidget {
  final int? accountId;
  final String title;
  const JournalScreen({super.key, this.accountId, this.title = 'Journal'});
  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    final where = widget.accountId == null ? '' : 'WHERE l.account_id = ${widget.accountId}';
    Db.q('SELECT l.*, j.date, j.ref, j.memo, a.name AS account FROM journal_lines l JOIN journal j ON j.id = l.journal_id '
            'JOIN accounts a ON a.id = l.account_id $where ORDER BY l.id DESC LIMIT 400')
        .then((r) {
      if (mounted) setState(() => _rows = r);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: _rows.isEmpty
            ? const Empty(Icons.menu_book_outlined, 'No entries.')
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: _rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, k) {
                  final l = _rows[k];
                  final dr = d(l['debit']), cr = d(l['credit']);
                  return Container(
                    decoration: box(),
                    child: ListTile(
                      dense: true,
                      title: Text(widget.accountId == null ? s(l['account']) : s(l['memo']), style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${s(l['ref'])} · ${dateText(l['date'])}${widget.accountId == null ? '\n${s(l['memo'])}' : ''}'),
                      trailing: Text(dr > 0 ? 'Dr ${money(dr, symbol: false)}' : 'Cr ${money(cr, symbol: false)}', style: h(13.5, color: dr > 0 ? C.ink : C.gold)),
                    ),
                  );
                },
              ),
      );
}

/// Balanced manual entry (opening balances, owner's money, corrections).
class ManualEntry extends StatefulWidget {
  const ManualEntry({super.key});
  @override
  State<ManualEntry> createState() => _ManualEntryState();
}

class _ManualEntryState extends State<ManualEntry> {
  List<Map<String, Object?>> _accounts = [];
  final List<(int, double, double)> _lines = [];
  final _memo = TextEditingController();

  @override
  void initState() {
    super.initState();
    Ledger.accounts().then((a) {
      if (mounted) setState(() => _accounts = a);
    });
  }

  String _name(int id) => s(_accounts.firstWhere((a) => n(a['id']) == id, orElse: () => {'name': '?'})['name']);

  Future<void> _add(bool debit) async {
    final a = await pickFrom(context, debit ? 'Debit account' : 'Credit account', _accounts, label: (m) => '${s(m['code'])}  ${s(m['name'])}');
    if (a == null || !mounted) return;
    final v = numIn(await ask(context, '${debit ? 'Debit' : 'Credit'} ${a['name']}', number: true));
    if (v == null || v <= 0) return;
    setState(() => _lines.add((n(a['id']), debit ? v : 0.0, debit ? 0.0 : v)));
  }

  Future<void> _save() async {
    final dr = _lines.fold<double>(0, (x, l) => x + l.$2), cr = _lines.fold<double>(0, (x, l) => x + l.$3);
    if ((dr - cr).abs() > 0.004 || dr == 0) {
      toast(context, 'Debits (${money(dr)}) must equal credits (${money(cr)}).');
      return;
    }
    final db = await Db.get();
    try {
      await db.transaction((tx) async {
        await Ledger.post(tx, ref: 'Manual', memo: _memo.text.trim().isEmpty ? 'Manual entry' : _memo.text.trim(), kind: 'manual',
            userId: Session.i.userId, lines: [for (final l in _lines) (l.$1, l.$2, l.$3, '')]);
        await Db.audit(tx, Session.i.userId, 'journal_manual', '${_memo.text.trim()} ${money(dr)}');
      });
      changed();
      if (mounted) {
        toast(context, 'Entry saved.');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dr = _lines.fold<double>(0, (x, l) => x + l.$2), cr = _lines.fold<double>(0, (x, l) => x + l.$3);
    return Scaffold(
      appBar: AppBar(title: const Text('Manual entry')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        const Text('Example: owner puts in KSh 50,000 cash → Debit Cash 50,000, Credit Owner\'s capital 50,000.', style: muted),
        const SizedBox(height: 10),
        TextField(controller: _memo, decoration: const InputDecoration(labelText: 'Description')),
        const SizedBox(height: 10),
        Container(
          decoration: box(),
          child: Column(children: [
            for (final l in _lines)
              ListTile(
                title: Text(_name(l.$1)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(l.$2 > 0 ? 'Dr ${money(l.$2, symbol: false)}' : 'Cr ${money(l.$3, symbol: false)}', style: h(14)),
                  IconButton(onPressed: () => setState(() => _lines.remove(l)), icon: const Icon(Icons.close)),
                ]),
              ),
            KV('Debits', money(dr)),
            KV('Credits', money(cr)),
          ]),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => _add(true), child: const Text('+ Debit'))),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton(onPressed: () => _add(false), child: const Text('+ Credit'))),
        ]),
        const SizedBox(height: 16),
        FilledButton(onPressed: _save, child: const Text('Save entry')),
      ]),
    );
  }
}

class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key});
  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  final _p = Period.thisMonth();
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.q(
        'SELECT e.*, a.name AS account, m.name AS method, u.name AS user FROM expenses e LEFT JOIN accounts a ON a.id = e.account_id '
        'LEFT JOIN pay_methods m ON m.id = e.method_id LEFT JOIN users u ON u.id = e.user_id WHERE e.date >= ? AND e.date < ? ORDER BY e.id DESC',
        [_p.a, _p.b]);
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _add() async {
    final accounts = await Db.q("SELECT * FROM accounts WHERE type = 'expense' AND active = 1 AND skey NOT IN ('cogs','stock_loss','cash_short') ORDER BY code");
    final methods = await Db.q("SELECT * FROM pay_methods WHERE active = 1 AND kind != 'credit' ORDER BY id");
    if (!mounted || accounts.isEmpty || methods.isEmpty) return;
    int acc = n(accounts.first['id']), met = n(methods.first['id']);
    final amount = TextEditingController();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('New expense'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<int>(
                value: acc,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'What for'),
                items: [for (final a in accounts) DropdownMenuItem(value: n(a['id']), child: Text(s(a['name'])))],
                onChanged: (v) => set(() => acc = v ?? acc),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                value: met,
                decoration: const InputDecoration(labelText: 'Paid by'),
                items: [for (final m in methods) DropdownMenuItem(value: n(m['id']), child: Text(s(m['name'])))],
                onChanged: (v) => set(() => met = v ?? met),
              ),
              const SizedBox(height: 10),
              TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount', prefixText: 'KSh ')),
              const SizedBox(height: 10),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'Note')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(minimumSize: const Size(0, 42)), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await Expenses.record(accountId: acc, methodId: met, amount: numIn(amount.text) ?? 0, note: note.text.trim());
      changed();
      _load();
    } on SaleError catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _rows.fold<double>(0, (a, e) => a + d(e['amount']));
    return Scaffold(
      appBar: AppBar(title: const Text('Expenses')),
      floatingActionButton: Session.i.can(P.expenses) ? FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Expense')) : null,
      body: Column(children: [
        PeriodBar(period: _p, onChanged: _load),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Row(children: [Text('${_rows.length} expenses', style: muted), const Spacer(), Text(money(total), style: h(15))]),
        ),
        Expanded(
          child: _rows.isEmpty
              ? const Empty(Icons.receipt_outlined, 'No expenses in this period.')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, k) {
                    final e = _rows[k];
                    return Container(
                      decoration: box(),
                      child: ListTile(
                        title: Text(s(e['account']), style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${dateText(e['date'])} · ${s(e['method'])} · ${s(e['user'])}${s(e['note']).isEmpty ? '' : '\n${s(e['note'])}'}'),
                        trailing: Text(money(d(e['amount'])), style: h(14)),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
