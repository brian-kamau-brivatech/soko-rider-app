import 'package:flutter/material.dart';
import '../api.dart';
import '../receipt.dart';
import '../store.dart';
import '../ui.dart';
import 'shift_screen.dart';

/// Cashier, shift, stock and settings.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget item(IconData icon, String title, String sub, Widget page) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: card(),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: CircleAvatar(backgroundColor: C.greenLight, child: Icon(icon, color: C.green)),
            title: Text(title, style: h(16)),
            subtitle: Text(sub),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
          ),
        );
    final s = Store.i;
    return SafeArea(
      bottom: false,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
        Text('More', style: h(22)),
        Text('${s.companyName} · ${s.configName}', style: const TextStyle(color: C.muted)),
        const SizedBox(height: 14),
        if (s.cashiersOn && s.cashierName.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: card(),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              leading: const CircleAvatar(backgroundColor: C.navy, child: Icon(Icons.badge_rounded, color: Colors.white)),
              title: Text(s.cashierName, style: h(16)),
              subtitle: Text('${s.isManager ? 'Manager' : 'Cashier'} · tap to switch / lock'),
              trailing: const Icon(Icons.logout_rounded),
              onTap: () => s.clearCashier(),
            ),
          ),
        item(Icons.lock_clock_rounded, 'Shift', 'Open or close: stock count and cash count', const ShiftScreen()),
        item(Icons.inventory_2_rounded, 'Stock', 'What is in the bar and in the store', const StockScreen()),
        item(Icons.settings_rounded, 'Settings', 'Printer and this handheld', const SettingsScreen()),
      ]),
    );
  }
}

class StockScreen extends StatefulWidget {
  const StockScreen({super.key});
  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  List<Map<String, dynamic>>? _items;
  String _bar = '';
  String _store = '';
  String? _error;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.call('/utange/pos/stock', Store.i.base());
      if (mounted) {
        setState(() {
          _items = ll(r['products']);
          _bar = ss(r['bar']);
          _store = ss(r['store']);
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final items = (_items ?? const <Map<String, dynamic>>[]).where((p) => q.isEmpty || ss(p['name']).toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: bar('Stock'),
      body: RefreshIndicator(
        color: C.green,
        onRefresh: _load,
        child: Loader(
          loading: _items == null,
          error: _error,
          onRetry: _load,
          child: () => ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
            Text(_store.isEmpty ? _bar : 'Bar: $_bar · Store: $_store', style: const TextStyle(color: C.muted)),
            const SizedBox(height: 8),
            TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: 'Search item',
                prefixIcon: const Icon(Icons.search_rounded),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
              ),
            ),
            const SizedBox(height: 10),
            if (items.isEmpty) const EmptyNote(Icons.inventory_2_outlined, 'No stock-tracked items.'),
            for (final p in items)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: card(14),
                child: Row(children: [
                  Expanded(child: Text(ss(p['name']), style: h(14, w: FontWeight.w700))),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('Bar ${qty(dd(p['bar']))}', style: h(14.5, color: dd(p['bar']) <= 0 ? C.red : C.ink)),
                    if (p['store'] != null) Text('Store ${qty(dd(p['store']))}', style: const TextStyle(color: C.muted, fontSize: 12.5)),
                  ]),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _printer = 'auto';
  String _printerLabel = 'Automatic';
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _loadPrinter();
  }

  Future<void> _loadPrinter() async {
    final id = await Receipt.printerChoice();
    var label = id == 'auto' ? 'Automatic' : id == 'dialog' ? 'Android print screen (preview)' : id;
    if (id != 'auto' && id != 'dialog') {
      final info = await Receipt.printerInfo();
      for (final p in (info['printers'] as List?) ?? const []) {
        if (p is Map && p['id'] == id) label = '${p['label']}';
      }
    }
    if (mounted) {
      setState(() {
        _printer = id;
        _printerLabel = label;
      });
    }
  }

  Future<void> _pickPrinter() async {
    final info = await Receipt.printerInfo();
    if (!mounted) return;
    final printers = ((info['printers'] as List?) ?? const []).whereType<Map>().toList();
    final options = <(String, String, String)>[
      ('auto', 'Automatic', printers.isEmpty ? 'No direct printer found: uses the print screen' : 'First printer that prints without a preview'),
      for (final p in printers) ('${p['id']}', '${p['label']}', '${p['package']}'),
      ('dialog', 'Android print screen', 'Shows a preview first'),
    ];
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Printer', style: h(18))),
          for (final o in options)
            ListTile(
              leading: Icon(_printer == o.$1 ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: _printer == o.$1 ? C.green : C.muted),
              title: Text(o.$2, style: h(15, w: FontWeight.w700)),
              subtitle: Text(o.$3),
              onTap: () => Navigator.pop(ctx, o.$1),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text('Bluetooth printer not listed? Switch it on, pair it in Android Bluetooth settings, allow "Nearby devices", '
                'then open Printer again.', style: TextStyle(color: C.muted, fontSize: 12.5)),
          ),
        ]),
      ),
    );
    if (picked == null) return;
    await Receipt.setPrinterChoice(picked);
    await _loadPrinter();
  }

  Future<void> _testPrint() async {
    setState(() => _testing = true);
    final sale = Sale.fromJson({
      'id': 0, 'name': 'TEST PRINT', 'ref': 'Printer test', 'date': DateTime.now().toString().substring(0, 16), 'amount': 0,
      'cashier': Store.i.cashierName.isEmpty ? 'Utange POS' : Store.i.cashierName,
      'payments': [], 'lines': [{'name': 'Printer test', 'qty': 1, 'price': 0, 'total': 0}],
    });
    final ok = await Receipt.print(sale, shop: Store.i.companyName);
    if (!mounted) return;
    setState(() => _testing = false);
    toast(context, !ok
        ? (Receipt.lastMethod == 'bt_failed' ? 'The Bluetooth printer did not answer.' : 'Could not print.')
        : Receipt.lastMethod == 'dialog'
            ? 'Used the Android print screen. Pick your printer above.'
            : 'Printed.');
  }

  Future<void> _changeDevice() async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set up this handheld again?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('For BRV: enter the device PIN to change the server or the Point of Sale.'),
          TextField(controller: c, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Device PIN')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim() == Store.i.pin), child: const Text('Set up again')),
        ],
      ),
    );
    if (ok == true) {
      await Store.i.forgetDevice();
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } else if (ok == false && c.text.isNotEmpty && mounted) {
      toast(context, 'Wrong device PIN.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Store.i;
    return Scaffold(
      appBar: bar('Settings'),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
        Container(
          decoration: card(),
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.print_outlined, color: C.navy),
              title: const Text('Printer'),
              subtitle: Text(_printerLabel),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _pickPrinter,
            ),
            ListTile(
              leading: const Icon(Icons.print_rounded, color: C.green),
              title: const Text('Test print'),
              trailing: _testing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
              onTap: _testing ? null : _testPrint,
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined, color: C.navy),
              title: const Text('Reload logo from Odoo'),
              subtitle: const Text('Printed at the top of receipts'),
              onTap: () async {
                await s.loadLogo();
                if (context.mounted) toast(context, s.logo == null ? 'No logo found.' : 'Logo updated.');
              },
            ),
          ]),
        ),
        const SizedBox(height: 14),
        Container(
          decoration: card(),
          child: Column(children: [
            ListTile(leading: const Icon(Icons.link_rounded), title: Text(s.server), subtitle: Text('Database ${s.db}')),
            ListTile(leading: const Icon(Icons.storefront_rounded), title: Text(s.configName), subtitle: Text(s.companyName)),
            ListTile(
              leading: const Icon(Icons.restart_alt_rounded, color: C.red),
              title: const Text('Set up again (BRV)', style: TextStyle(color: C.red, fontWeight: FontWeight.w700)),
              onTap: _changeDevice,
            ),
          ]),
        ),
      ]),
    );
  }
}
