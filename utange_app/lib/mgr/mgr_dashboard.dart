import 'dart:async';
import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'mgr_sheets.dart';
import 'mgr_shell.dart';

class MgrDashboard extends StatefulWidget {
  const MgrDashboard({super.key});
  @override
  State<MgrDashboard> createState() => _MgrDashboardState();
}

class _MgrDashboardState extends State<MgrDashboard> {
  Map<String, dynamic>? _d;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mgrTab.value == 0) _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await Api.call('/utange/mgr/dashboard', {});
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok == true) await Store.i.managerSignOut();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Column(children: [
      Container(
        width: double.infinity,
        color: C.navy,
        padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 12, 8, 16),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Today', style: h(22, color: Colors.white)),
              Text('${Store.i.companyName} · ${Store.i.managerName}', style: const TextStyle(color: Color(0xFFC9D3E0), fontSize: 13)),
            ]),
          ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded, color: Colors.white)),
          IconButton(onPressed: _signOut, icon: const Icon(Icons.logout_rounded, color: Colors.white)),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          color: C.green,
          onRefresh: _load,
          child: Loader(
            loading: d == null,
            error: _error,
            onRetry: _load,
            child: () => _body(d!),
          ),
        ),
      ),
    ]);
  }

  Widget _body(Map<String, dynamic> d) {
    final today = Map<String, dynamic>.from(d['today'] as Map? ?? const {});
    final shifts = ll(d['shifts']);
    final recent = ll(d['recent_sheets']).map(SheetRow.fromJson).toList();
    final toApprove = ii(d['to_approve']);
    final toIssue = ii(d['to_issue']);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Sales today', style: TextStyle(color: C.muted)),
          Row(children: [
            Expanded(child: Text(ksh(dd(today['total'])), style: h(28))),
            Text('${ii(today['count'])} sales', style: h(15, color: C.muted)),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final m in ll(today['by_method'])) Pill('${ss(m['method'])} ${ksh(dd(m['amount']))}', fg: C.navy, bg: C.blueLight),
          ]),
        ]),
      ),
      const SizedBox(height: 12),
      Material(
        color: toApprove > 0 ? C.amberLight : Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: C.line)),
          leading: Icon(Icons.assignment_late_rounded, color: toApprove > 0 ? C.amber : C.muted, size: 30),
          title: Text(toApprove > 0 ? '$toApprove requests to approve' : 'No requests waiting', style: h(16)),
          subtitle: Text(toIssue > 0 ? '$toIssue approved, waiting for the store to issue' : 'Tap to see all requests'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => mgrTab.value = 1,
        ),
      ),
      const SizedBox(height: 16),
      Text('Open shifts', style: h(17)),
      const SizedBox(height: 8),
      if (shifts.isEmpty) const EmptyNote(Icons.lock_rounded, 'No shift is open.'),
      for (final s in shifts)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: card(),
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            leading: const CircleAvatar(backgroundColor: C.greenLight, child: Icon(Icons.lock_open_rounded, color: C.green)),
            title: Text('${ss(s['config'])} · ${ss(s['session'])}', style: h(15)),
            subtitle: Text([
              'Since ${ss(s['since']).length >= 16 ? ss(s['since']).substring(11, 16) : ss(s['since'])}',
              '${ii(s['orders'])} sales · ${ksh(dd(s['sales']))}',
              if (ss(s['sheet']).isEmpty || s['outside'] == true) 'No opening count'
              else if (ii(s['open_diffs']) > 0) '${ii(s['open_diffs'])} opening differences'
              else 'Opening count OK',
            ].join('\n')),
            trailing: ii(s['sheet_id']) > 0 ? const Icon(Icons.chevron_right_rounded) : null,
            onTap: ii(s['sheet_id']) > 0
                ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SheetDetail(sheetId: ii(s['sheet_id']))))
                : null,
          ),
        ),
      const SizedBox(height: 8),
      Text('Last closed shifts', style: h(17)),
      const SizedBox(height: 8),
      if (recent.isEmpty) const EmptyNote(Icons.fact_check_outlined, 'No closed stock sheets yet.'),
      for (final r in recent) SheetTile(r),
    ]);
  }
}
