import 'dart:convert';
import 'package:flutter/material.dart';
import '../db.dart';
import '../fmt.dart';
import '../sync.dart';
import '../ui.dart';

/// Records Odoo refused (e.g. waybill number already used) or still waiting for another terminal.
class ProblemsScreen extends StatefulWidget {
  const ProblemsScreen({super.key});
  @override
  State<ProblemsScreen> createState() => _ProblemsScreenState();
}

class _ProblemsScreenState extends State<ProblemsScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _rows = await (await Db.get()).rawQuery("SELECT * FROM outbox WHERE status = 'failed' OR tries > 0 ORDER BY seq");
    if (mounted) setState(() {});
  }

  Future<void> _retry(Map<String, Object?> r) async {
    await (await Db.get()).rawUpdate("UPDATE outbox SET status = 'pending', error = '' WHERE seq = ?", [r['seq']]);
    await Sync.i.run();
    _load();
  }

  Future<void> _discard(Map<String, Object?> r) async {
    final sup = await askSupervisor(context, 'Discard this record (${r['kind']} ${r['ref']}). It will never reach Odoo.');
    if (sup == null) return;
    await (await Db.get()).delete('outbox', where: 'seq = ?', whereArgs: [r['seq']]);
    await Sync.i.counts();
    Sync.i.changed();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sync problems')),
      body: _rows.isEmpty
          ? const Empty(Icons.cloud_done_outlined, 'Nothing to check. Everything reached Odoo or is waiting to be sent.')
          : ListView(padding: const EdgeInsets.all(12), children: [
              for (final r in _rows)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: box(color: r['status'] == 'failed' ? C.redLight : C.amberLight, border: false),
                  child: ListTile(
                    title: Text('${r['kind']} · ${r['ref']}', style: h(15)),
                    subtitle: Text('${s(r['error'])}\n${s(r['status']) == 'failed' ? 'Refused by Odoo' : 'Waiting (${r['tries']} tries)'} · ${s(r['created']).replaceFirst('T', ' ').split('.').first}'),
                    isThreeLine: true,
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) => v == 'retry' ? _retry(r) : (v == 'discard' ? _discard(r) : showDialog(context: context, builder: (_) => AlertDialog(content: SingleChildScrollView(child: Text(const JsonEncoder.withIndent('  ').convert(jsonDecode(s(r['data']))))))) ),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'retry', child: Text('Send again')),
                        PopupMenuItem(value: 'view', child: Text('Details')),
                        PopupMenuItem(value: 'discard', child: Text('Discard (supervisor)')),
                      ],
                    ),
                  ),
                ),
            ]),
    );
  }
}
