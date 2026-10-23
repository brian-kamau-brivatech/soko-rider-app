import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../db.dart';
import '../ui.dart';

/// Every request sent to the VSCU and what came back (last 2000).
class CallsScreen extends StatefulWidget {
  const CallsScreen({super.key});
  @override
  State<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends State<CallsScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await Db.get();
    final r = await db.query('calls', orderBy: 'id DESC', limit: 300);
    if (mounted) {
      setState(() {
        _rows = r.map((e) => Map<String, dynamic>.from(e)).toList();
        _loading = false;
      });
    }
  }

  String _pretty(String? s) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(s ?? ''));
    } catch (_) {
      return s ?? '';
    }
  }

  void _open(Map<String, dynamic> r) {
    final text = 'POST /${r['path']}\n${r['created_at']} · ${r['ms']} ms\n\nREQUEST\n${_pretty(r['request'] as String?)}'
        '\n\nRESPONSE\n${_pretty(r['response'] as String?)}';
    Navigator.of(context).push(MaterialPageRoute(
      builder: (ctx) => Scaffold(
        appBar: AppBar(title: Text('/${r['path']}', style: h(16)), actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_rounded),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              toast(ctx, 'Copied.');
            },
          ),
        ]),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('VSCU call log', style: h(18))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rows.isEmpty
              ? const EmptyNote(Icons.history_rounded, 'No calls yet.')
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = _rows[i];
                      final ok = r['ok'] == 1;
                      final t = DateTime.tryParse('${r['created_at']}');
                      return ListTile(
                        leading: Icon(ok ? Icons.check_circle_rounded : Icons.error_rounded, color: ok ? C.green : C.red),
                        title: Text('/${r['path']}', style: h(14, w: FontWeight.w700)),
                        subtitle: Text(
                          '${t == null ? '' : '${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'}'
                          ' · ${r['ms']} ms · ${(r['code'] ?? '').toString().isEmpty ? '' : '${r['code']} '}${r['msg'] ?? ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _open(r),
                      );
                    },
                  ),
                ),
    );
  }
}
