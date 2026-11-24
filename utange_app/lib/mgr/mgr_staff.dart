import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';

// ---------------------------------------------------------------------------
// Employees bills: credit sales to staff, cleared by a manager when paid / deducted
// ---------------------------------------------------------------------------
class StaffBillsScreen extends StatefulWidget {
  const StaffBillsScreen({super.key});
  @override
  State<StaffBillsScreen> createState() => _StaffBillsScreenState();
}

class _StaffBillsScreenState extends State<StaffBillsScreen> {
  String _state = 'open';
  int _employee = 0;
  Map<String, dynamic>? _r;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await Api.call('/utange/mgr/staff_bills', {'state': _state, 'employee_id': _employee});
      if (mounted) setState(() => _r = r);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  Future<void> _clear({List<int>? ids, int? employeeId, String who = '', bool undo = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(undo ? 'Open the bill again?' : 'Clear ${ids != null && ids.length == 1 ? 'this bill' : 'all open bills of $who'}?'),
        content: Text(undo ? 'It goes back to the open employees bills.' : 'Clear when the employee has paid, or it was deducted from pay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(undo ? 'Open again' : 'Clear')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final r = await Api.call('/utange/mgr/staff_bill_clear', {
        if (ids != null) 'order_ids': ids,
        if (employeeId != null) 'employee_id': employeeId,
        'undo': undo,
      });
      if (mounted) toast(context, ss(r['message']));
      await _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
      await Store.i.handle(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final people = ll(r?['people']);
    final bills = ll(r?['bills']);
    return Scaffold(
      appBar: bar('Employees bills', actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))]),
      body: Column(children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(children: [
            for (final s in const [('open', 'Not cleared'), ('cleared', 'Cleared'), ('all', 'All')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(s.$2),
                  selected: _state == s.$1,
                  onSelected: (_) {
                    setState(() => _state = s.$1);
                    _load();
                  },
                ),
              ),
            const Spacer(),
            if (_employee != 0)
              ActionChip(
                avatar: const Icon(Icons.close_rounded, size: 16),
                label: const Text('Everyone'),
                onPressed: () {
                  setState(() => _employee = 0);
                  _load();
                },
              ),
          ]),
        ),
        Expanded(
          child: Loader(
            loading: r == null,
            error: _error,
            onRetry: _load,
            child: () => RefreshIndicator(
              color: C.green,
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
                if (_state != 'cleared')
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: C.navy, borderRadius: BorderRadius.circular(18)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Owed by staff (not cleared)', style: TextStyle(color: Color(0xFFC9D3E0))),
                      Text(ksh(dd(r?['total_open'])), style: h(26, color: Colors.white)),
                    ]),
                  ),
                const SizedBox(height: 12),
                if (people.isEmpty) const EmptyNote(Icons.badge_outlined, 'No employees bills here.'),
                if (_employee == 0 && people.isNotEmpty) ...[
                  Text('Per employee', style: h(15)),
                  const SizedBox(height: 6),
                  for (final p in people)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: card(14),
                      child: ListTile(
                        title: Text(ss(p['name']), style: h(14.5, w: FontWeight.w700)),
                        subtitle: Text('${ii(p['count'])} bills${dd(p['cleared']) > 0 ? ' · cleared ${ksh(dd(p['cleared']))}' : ''}'),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(ksh(dd(p['open'])), style: h(15, color: dd(p['open']) > 0 ? C.red : C.green)),
                          if (dd(p['open']) > 0)
                            IconButton(
                              tooltip: 'Clear all',
                              onPressed: _busy ? null : () => _clear(employeeId: ii(p['employee_id']), who: ss(p['name'])),
                              icon: const Icon(Icons.done_all_rounded, color: C.green),
                            ),
                        ]),
                        onTap: () {
                          setState(() => _employee = ii(p['employee_id']));
                          _load();
                        },
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
                if (bills.isNotEmpty) Text(_employee == 0 ? 'Bills' : 'Bills of ${ss(bills.first['employee'])}', style: h(15)),
                const SizedBox(height: 6),
                for (final b in bills)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: b['cleared'] == true ? C.line : C.red.withValues(alpha: 0.4)),
                    ),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${ss(b['employee'])} · ${ksh(dd(b['amount']))}', style: h(14.5, w: FontWeight.w700)),
                          Text(ss(b['items']), style: const TextStyle(fontSize: 12.5)),
                          Text(
                              [
                                ss(b['date']).length >= 16 ? ss(b['date']).substring(0, 16) : ss(b['date']),
                                if (ss(b['by']).isNotEmpty) 'by ${b['by']}',
                                if (ss(b['reason']).isNotEmpty) ss(b['reason']),
                              ].join(' · '),
                              style: const TextStyle(color: C.muted, fontSize: 12)),
                          if (b['cleared'] == true)
                            Text('Cleared by ${ss(b['cleared_by'])} ${ss(b['cleared_on']).length >= 10 ? ss(b['cleared_on']).substring(0, 10) : ''}',
                                style: const TextStyle(color: C.green, fontSize: 12, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                      b['cleared'] == true
                          ? IconButton(
                              tooltip: 'Open again',
                              onPressed: _busy ? null : () => _clear(ids: [ii(b['id'])], undo: true),
                              icon: const Icon(Icons.undo_rounded, color: C.muted),
                            )
                          : TextButton(
                              onPressed: _busy ? null : () => _clear(ids: [ii(b['id'])]),
                              child: const Text('Clear'),
                            ),
                    ]),
                  ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Staff rights: waiter (orders, kitchen tickets, bill) or cashier (also takes payment), or custom
// ---------------------------------------------------------------------------
class StaffRightsScreen extends StatefulWidget {
  const StaffRightsScreen({super.key});
  @override
  State<StaffRightsScreen> createState() => _StaffRightsScreenState();
}

class _StaffRightsScreenState extends State<StaffRightsScreen> {
  Map<String, dynamic>? _r;
  String? _error;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await Api.call('/utange/mgr/staff', {});
      if (mounted) setState(() => _r = r);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      await Store.i.handle(e);
    }
  }

  static const _roles = {
    'waiter': ('Waiter', 'Takes orders, sends them to the kitchen / bar, prints the bill. Cannot take payment.'),
    'cashier': ('Cashier', 'Also takes payment, opens and closes shifts.'),
    'full': ('Everything', 'No limits (managers).'),
    'custom': ('Custom', 'Chosen rights below.'),
  };

  Future<void> _edit(Map<String, dynamic> e) async {
    final labels = ll(_r?['perm_labels']);
    var role = ss(e['role']);
    final perms = Map<String, bool>.from({for (final x in (e['perms'] as Map).entries) '${x.key}': x.value == true});
    final res = await showModalBottomSheet<(String, Map<String, bool>)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
              Text(ss(e['name']), style: h(19)),
              Text([if (ss(e['job']).isNotEmpty) ss(e['job']), if (ss(e['login']).isNotEmpty) 'login ${e['login']}'].join(' · '),
                  style: const TextStyle(color: C.muted)),
              const SizedBox(height: 10),
              for (final k in const ['waiter', 'cashier', 'full'])
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: k,
                  groupValue: role,
                  title: Text(_roles[k]!.$1, style: h(15, w: FontWeight.w700)),
                  subtitle: Text(_roles[k]!.$2),
                  onChanged: (v) => set(() {
                    role = v ?? role;
                    if (role == 'waiter') {
                      perms.updateAll((p, _) => p == 'sell' || p == 'requisition');
                    } else if (role == 'cashier') {
                      perms.updateAll((p, _) => const {'sell', 'charge', 'open', 'close', 'requisition'}.contains(p));
                    } else {
                      perms.updateAll((p, _) => true);
                    }
                  }),
                ),
              const Divider(color: C.line),
              Text('Rights', style: h(15)),
              for (final l in labels)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: perms[ss(l['key'])] ?? false,
                  title: Text(ss(l['label'])),
                  onChanged: (v) => set(() {
                    perms[ss(l['key'])] = v ?? false;
                    role = 'custom';
                  }),
                ),
              const SizedBox(height: 10),
              primaryButton('Save', () => Navigator.pop(ctx, (role, perms)), icon: Icons.save_rounded),
            ]),
          ),
        ),
      ),
    );
    if (res == null) return;
    try {
      final r = await Api.call('/utange/mgr/staff_set', {
        'employee_id': e['id'],
        'role': res.$1 == 'custom' ? null : res.$1,
        'perms': res.$2,
      });
      if (mounted) toast(context, ss(r['message']));
      await _load();
    } on ApiError catch (err) {
      if (mounted) toast(context, err.message);
      await Store.i.handle(err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final q = _q.trim().toLowerCase();
    final staff = ll(r?['staff']).where((e) => q.isEmpty || ss(e['name']).toLowerCase().contains(q)).toList();
    final canEdit = r?['can_edit'] == true;
    return Scaffold(
      appBar: bar('Staff rights', actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))]),
      body: Loader(
        loading: r == null,
        error: _error,
        onRetry: _load,
        child: () => RefreshIndicator(
          color: C.green,
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
            TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: 'Search staff',
                prefixIcon: const Icon(Icons.search_rounded),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.line)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
                canEdit
                    ? 'Tap a person to make them a waiter or a cashier (e.g. a waiter who becomes cashier for the night). '
                        'The change applies at their next action on the handheld.'
                    : 'Only POS managers can change rights.',
                style: const TextStyle(color: C.muted, fontSize: 12.5)),
            const SizedBox(height: 10),
            for (final e in staff)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: card(14),
                child: ListTile(
                  title: Text(ss(e['name']), style: h(14.5, w: FontWeight.w700)),
                  subtitle: Text(
                      [
                        if (ss(e['job']).isNotEmpty) ss(e['job']),
                        if (e['pos_manager'] == true) 'POS manager',
                        if (e['approver'] == true) 'approves counts',
                        if (e['has_pin'] != true) 'no PIN',
                      ].join(' · '),
                      style: const TextStyle(fontSize: 12.5)),
                  trailing: _rolePill(e),
                  onTap: canEdit && e['admin'] != true ? () => _edit(e) : null,
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _rolePill(Map<String, dynamic> e) {
    if (e['admin'] == true) return const Pill('Admin', fg: C.navy, bg: C.blueLight);
    return switch (ss(e['role'])) {
      'waiter' => const Pill('Waiter', fg: C.amber, bg: C.amberLight),
      'cashier' => const Pill('Cashier'),
      'custom' => Pill((e['perms'] as Map)['charge'] == true ? 'Custom · charges' : 'Custom · no payment', fg: C.navy, bg: C.blueLight),
      _ => const Pill('Everything', fg: C.navy, bg: C.blueLight),
    };
  }
}
