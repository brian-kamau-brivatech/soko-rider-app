import 'package:sqflite/sqflite.dart';
import 'db.dart';
import 'fmt.dart';

/// Double-entry accounting: every money event posts a balanced journal entry.
class Ledger {
  /// lines: (account id, debit, credit, partner). Zero lines are dropped. Throws if not balanced.
  static Future<int> post(DatabaseExecutor tx,
      {required String ref, required String memo, required String kind, required int userId,
      required List<(int, double, double, String)> lines, String? date}) async {
    final kept = [
      for (final l in lines)
        if (r2(l.$2).abs() > 0.004 || r2(l.$3).abs() > 0.004) l
    ];
    if (kept.isEmpty) return 0;
    final dr = kept.fold<double>(0, (a, l) => a + r2(l.$2));
    final cr = kept.fold<double>(0, (a, l) => a + r2(l.$3));
    if ((dr - cr).abs() > 0.02) {
      throw StateError('Journal $ref not balanced: debit ${money(dr)} credit ${money(cr)}');
    }
    final jid = await tx.insert('journal', {'date': date ?? nowIso(), 'ref': ref, 'memo': memo, 'kind': kind, 'user_id': userId});
    for (final l in kept) {
      // negative amounts go to the other side
      var debit = r2(l.$2), credit = r2(l.$3);
      if (debit < 0) {
        credit += -debit;
        debit = 0;
      }
      if (credit < 0) {
        debit += -credit;
        credit = 0;
      }
      await tx.insert('journal_lines', {'journal_id': jid, 'account_id': l.$1, 'debit': debit, 'credit': credit, 'partner': l.$4});
    }
    return jid;
  }

  /// Balance of each account up to [to] (and from [from]): {account id: debit - credit}.
  static Future<Map<int, double>> balances({String? from, String? to}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (from != null) {
      where.add('j.date >= ?');
      args.add(from);
    }
    if (to != null) {
      where.add('j.date < ?');
      args.add(to);
    }
    final rows = await Db.q(
        'SELECT l.account_id a, SUM(l.debit) - SUM(l.credit) b FROM journal_lines l JOIN journal j ON j.id = l.journal_id '
        '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} GROUP BY l.account_id',
        args);
    return {for (final r in rows) n(r['a']): d(r['b'])};
  }

  static Future<List<Map<String, Object?>>> accounts() => Db.q('SELECT * FROM accounts WHERE active = 1 ORDER BY code');

  /// Profit and loss for a period: income and expense accounts with their totals.
  static Future<Map<String, Object>> profitAndLoss(String from, String to) async {
    final b = await balances(from: from, to: to);
    final income = <(String, double)>[];
    final expense = <(String, double)>[];
    for (final a in await accounts()) {
      final v = b[n(a['id'])] ?? 0;
      if (v.abs() < 0.005) continue;
      if (s(a['type']) == 'income') income.add((s(a['name']), -v));
      if (s(a['type']) == 'expense') expense.add((s(a['name']), v));
    }
    final ti = income.fold<double>(0, (x, e) => x + e.$2);
    final te = expense.fold<double>(0, (x, e) => x + e.$2);
    return {'income': income, 'expense': expense, 'total_income': ti, 'total_expense': te, 'profit': ti - te};
  }

  /// Balance sheet at a date: assets = liabilities + equity (+ profit so far).
  static Future<Map<String, Object>> balanceSheet(String to) async {
    final b = await balances(to: to);
    final assets = <(String, double)>[];
    final liab = <(String, double)>[];
    final equity = <(String, double)>[];
    var profit = 0.0;
    for (final a in await accounts()) {
      final v = b[n(a['id'])] ?? 0;
      switch (s(a['type'])) {
        case 'asset':
          if (v.abs() >= 0.005) assets.add((s(a['name']), v));
        case 'liability':
          if (v.abs() >= 0.005) liab.add((s(a['name']), -v));
        case 'equity':
          if (v.abs() >= 0.005) equity.add((s(a['name']), -v));
        case 'income':
          profit += -v;
        case 'expense':
          profit -= v;
      }
    }
    equity.add(('Profit (retained)', profit));
    double t(List<(String, double)> l) => l.fold<double>(0, (x, e) => x + e.$2);
    return {'assets': assets, 'liabilities': liab, 'equity': equity, 'total_assets': t(assets), 'total_liabilities': t(liab), 'total_equity': t(equity)};
  }
}
