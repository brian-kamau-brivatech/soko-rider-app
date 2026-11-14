import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../backup.dart';
import '../bus.dart';
import '../db.dart';
import '../fmt.dart';
import '../receipt.dart';
import '../session.dart';
import '../settings.dart';
import '../ui.dart';

class BusinessSettings extends StatefulWidget {
  const BusinessSettings({super.key});
  @override
  State<BusinessSettings> createState() => _BusinessSettingsState();
}

class _BusinessSettingsState extends State<BusinessSettings> {
  final st = Settings.i;
  late final _name = TextEditingController(text: st.businessName);
  late final _phone = TextEditingController(text: st.phone);
  late final _email = TextEditingController(text: st.email);
  late final _address = TextEditingController(text: st.address);
  late final _pin = TextEditingController(text: st.taxPin);
  late final _header = TextEditingController(text: st.receiptHeader);
  late final _footer = TextEditingController(text: st.receiptFooter);
  List<Map<String, Object?>> _locs = [];

  @override
  void initState() {
    super.initState();
    Db.q('SELECT * FROM locations WHERE active = 1 ORDER BY name').then((l) {
      if (mounted) setState(() => _locs = l);
    });
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      toast(context, 'Enter the business name.');
      return;
    }
    await st.set('business_name', _name.text.trim());
    await st.set('phone', _phone.text.trim());
    await st.set('email', _email.text.trim());
    await st.set('address', _address.text.trim());
    await st.set('tax_pin', _pin.text.trim().toUpperCase());
    await st.set('receipt_header', _header.text.trim());
    await st.set('receipt_footer', _footer.text.trim());
    if (mounted) toast(context, 'Saved.');
  }

  /// Company logo for the top of receipts: picked from the phone, shrunk to receipt size, synced to every device.
  Future<void> _pickLogo() async {
    try {
      final bytes = await const MethodChannel('brv/print').invokeMethod<Uint8List>('pickFile');
      if (bytes == null) return;
      final codec = await ui.instantiateImageCodec(bytes);
      final src = (await codec.getNextFrame()).image;
      final codec2 = src.width > 320 ? await ui.instantiateImageCodec(bytes, targetWidth: 320) : null;
      final img = codec2 == null ? src : (await codec2.getNextFrame()).image;
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw 'not an image';
      await st.set('receipt_logo', base64Encode(png.buffer.asUint8List()));
      if (mounted) toast(context, 'Logo saved. It prints at the top of receipts.');
    } catch (_) {
      if (mounted) toast(context, 'Could not read that file. Choose a PNG or JPG picture.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final logo = st.get('receipt_logo');
    final sellLoc = int.tryParse(st.get('sell_location')) ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Business settings')),
      body: ListenableBuilder(
        listenable: st,
        builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          const Label('Business (printed on receipts)'),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: box(),
            child: Row(children: [
              Container(
                width: 84,
                height: 84,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: C.line)),
                child: logo.isEmpty
                    ? const Icon(Icons.image_outlined, size: 34, color: C.muted)
                    : Padding(padding: const EdgeInsets.all(4), child: Image.memory(base64Decode(logo), fit: BoxFit.contain, gaplessPlayback: true)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Receipt logo', style: TextStyle(fontWeight: FontWeight.w800)),
                  const Text('Printed at the top of every receipt. A dark logo on a white background prints best.',
                      style: TextStyle(color: C.muted, fontSize: 12.5)),
                  Wrap(spacing: 4, children: [
                    TextButton.icon(onPressed: _pickLogo, icon: const Icon(Icons.upload_outlined), label: Text(logo.isEmpty ? 'Upload logo' : 'Change')),
                    if (logo.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => st.set('receipt_logo', ''),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Remove'),
                      ),
                  ]),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Business name')),
          const SizedBox(height: 10),
          TextField(controller: _phone, decoration: const InputDecoration(labelText: 'Phone')),
          const SizedBox(height: 10),
          TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email')),
          const SizedBox(height: 10),
          TextField(controller: _address, decoration: const InputDecoration(labelText: 'Address')),
          const SizedBox(height: 10),
          TextField(controller: _pin, decoration: const InputDecoration(labelText: 'KRA PIN')),
          const SizedBox(height: 10),
          TextField(controller: _header, decoration: const InputDecoration(labelText: 'Receipt header line (e.g. Till / Paybill no.)')),
          const SizedBox(height: 10),
          TextField(controller: _footer, decoration: const InputDecoration(labelText: 'Receipt footer')),
          const SizedBox(height: 12),
          FilledButton(onPressed: _save, child: const Text('Save')),
          const Label('Selling rules'),
          Container(
            decoration: box(),
            child: Column(children: [
              SwitchListTile(value: st.vatRegistered, onChanged: (v) => st.setFlag('vat_registered', v), title: const Text('VAT registered'), subtitle: const Text('Prices include VAT; VAT is posted to the accounts.')),
              SwitchListTile(value: st.requireShift, onChanged: (v) => st.setFlag('require_shift', v), title: const Text('Session needed to sell'), subtitle: const Text('A session is opened with a cash float and closed with a cash count. Always on for BRV Pos Sales devices.')),
              SwitchListTile(value: st.blockNoStock, onChanged: (v) => st.setFlag('block_no_stock', v), title: const Text('Do not sell without stock'), subtitle: const Text('Unless the role has "Sell items that show no stock".')),
              SwitchListTile(value: st.printAfterSale, onChanged: (v) => st.setFlag('print_after_sale', v), title: const Text('Print the receipt after each sale')),
              ListTile(
                title: const Text('Lock after no touch'),
                subtitle: Text(st.lockMinutes == 0 ? 'Never' : '${st.lockMinutes} minutes'),
                trailing: DropdownButton<int>(
                  value: [0, 1, 2, 5, 10, 30].contains(st.lockMinutes) ? st.lockMinutes : 2,
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1 min')),
                    DropdownMenuItem(value: 2, child: Text('2 min')),
                    DropdownMenuItem(value: 5, child: Text('5 min')),
                    DropdownMenuItem(value: 10, child: Text('10 min')),
                    DropdownMenuItem(value: 30, child: Text('30 min')),
                    DropdownMenuItem(value: 0, child: Text('Never')),
                  ],
                  onChanged: (v) async {
                    await st.set('lock_minutes', '${v ?? 2}');
                    Session.i.lockMinutes = v ?? 2;
                    Session.i.touch();
                  },
                ),
              ),
              ListTile(
                title: const Text('Sell from (when no session)'),
                trailing: DropdownButton<int>(
                  value: _locs.any((l) => n(l['id']) == sellLoc) ? sellLoc : null,
                  hint: const Text('First shop'),
                  items: [for (final l in _locs) DropdownMenuItem(value: n(l['id']), child: Text(s(l['name'])))],
                  onChanged: (v) => st.set('sell_location', '${v ?? ''}'),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class PayMethodsScreen extends StatefulWidget {
  const PayMethodsScreen({super.key});
  @override
  State<PayMethodsScreen> createState() => _PayMethodsScreenState();
}

class _PayMethodsScreenState extends State<PayMethodsScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.q('SELECT m.*, a.name AS account FROM pay_methods m LEFT JOIN accounts a ON a.id = m.account_id ORDER BY m.id');
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _add() async {
    final name = await ask(context, 'New payment method', label: 'e.g. Equity Bank, Airtel Money, Voucher');
    if (name == null || name.trim().isEmpty) return;
    final db = await Db.get();
    final code = await Db.count("SELECT COALESCE(MAX(CAST(code AS INTEGER)), 1020) + 1 FROM accounts WHERE code BETWEEN '1000' AND '1099'");
    final acc = await Db.ins(db, 'accounts', {'code': '$code', 'name': name.trim(), 'type': 'asset'});
    await Db.ins(db, 'pay_methods', {'name': name.trim(), 'kind': 'other', 'account_id': acc});
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Payment methods')),
        floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 90), children: [
          const Padding(padding: EdgeInsets.fromLTRB(4, 0, 4, 10), child: Text('Each method has its own account, so you see how much is in cash, M-Pesa and the bank.', style: muted)),
          Container(
            decoration: box(),
            child: Column(children: [
              for (final m in _rows)
                SwitchListTile(
                  value: n(m['active']) == 1,
                  onChanged: (v) async {
                    final db = await Db.get();
                    await db.update('pay_methods', {'active': v ? 1 : 0}, where: 'id = ?', whereArgs: [m['id']]);
                    _load();
                  },
                  title: Text(s(m['name'])),
                  subtitle: Text('Account: ${s(m['account'])}'),
                ),
            ]),
          ),
        ]),
      );
}

class PrinterScreen extends StatefulWidget {
  const PrinterScreen({super.key});
  @override
  State<PrinterScreen> createState() => _PrinterScreenState();
}

class _PrinterScreenState extends State<PrinterScreen> {
  Map<String, dynamic>? _info;
  String _choice = 'auto';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final i = await Printer.info();
    final c = await Printer.choice();
    if (mounted) setState(() { _info = i; _choice = c; });
  }

  @override
  Widget build(BuildContext context) {
    final printers = ((_info?['printers'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final st = Settings.i;
    return Scaffold(
      appBar: AppBar(title: const Text('Printer'), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        const Text('Handheld POS with a built-in printer: leave on Automatic. Bluetooth printer: pair it in Android settings first, then choose it here.', style: muted),
        const SizedBox(height: 12),
        Container(
          decoration: box(),
          child: Column(children: [
            RadioListTile<String>(value: 'auto', groupValue: _choice, onChanged: (v) async { await Printer.setChoice('auto'); _load(); }, title: const Text('Automatic (built-in printer)')),
            for (final p in printers)
              RadioListTile<String>(
                value: '${p['id']}',
                groupValue: _choice,
                onChanged: (v) async { await Printer.setChoice('${p['id']}'); _load(); },
                title: Text('${p['label']}'),
              ),
            RadioListTile<String>(value: 'dialog', groupValue: _choice, onChanged: (v) async { await Printer.setChoice('dialog'); _load(); }, title: const Text('Android print dialog (any printer, PDF)')),
          ]),
        ),
        const Label('Paper'),
        Container(
          decoration: box(),
          child: Column(children: [
            RadioListTile<int>(value: 58, groupValue: st.paperMm, onChanged: (v) async { await st.set('paper_mm', '58'); setState(() {}); }, title: const Text('58 mm')),
            RadioListTile<int>(value: 80, groupValue: st.paperMm, onChanged: (v) async { await st.set('paper_mm', '80'); setState(() {}); }, title: const Text('80 mm')),
          ]),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () async {
            final ok = await Printer.printLines(const [PLine.center('Printer test', size: 24, bold: true), PLine.row('Item', '100.00'), PLine.dash(), PLine.row('TOTAL', 'KSh 100.00', bold: true)], 'Test');
            if (context.mounted) toast(context, ok ? 'Sent to the printer (${Printer.lastMethod}).' : 'Printing failed (${Printer.lastMethod}).');
          },
          icon: const Icon(Icons.print_outlined),
          label: const Text('Print a test'),
        ),
      ]),
    );
  }
}

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});
  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  DateTime? _last;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Backup.last().then((v) {
      if (mounted) setState(() => _last = v);
    });
  }

  Future<void> _save(bool share) async {
    setState(() => _busy = true);
    try {
      final uri = await Backup.save(share: share);
      final l = await Backup.last();
      if (mounted) {
        setState(() => _last = l);
        toast(context, uri == null ? 'Could not save the backup.' : 'Backup saved in Downloads/BRV Pos Sales/Backups.');
      }
    } catch (e) {
      if (mounted) toast(context, 'Backup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    try {
      final b = await Backup.pick();
      if (b == null || !mounted) return;
      if (!await confirm(context, 'Replace everything on this phone?', '${Backup.summary(b)}\n\nAll current data is replaced by this backup.', ok: 'Restore', danger: true)) return;
      await Backup.restore(b);
      changed();
      if (mounted) toast(context, 'Restored. Sign in again.');
      Session.i.lock();
    } on FormatException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, 'Restore failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Backup and restore')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: box(color: C.ink, border: false),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('All your data lives on this phone.', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 6),
              const Text('A copy is saved on this phone when the app starts, in Downloads/BRV Pos Sales/Backups. '
                  'Share it to Google Drive or Gmail for your own records.',
                  style: TextStyle(color: Color(0xFFCBD5E1))),
              const SizedBox(height: 10),
              Text('Last backup: ${_last == null ? 'never' : dateText(_last!.toIso8601String())}', style: h(14, color: C.gold)),
            ]),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _busy ? null : () => _save(true), icon: const Icon(Icons.cloud_upload_outlined), label: const Text('Back up and share (Drive, Gmail...)')),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: _busy ? null : () => _save(false), icon: const Icon(Icons.save_alt), label: const Text('Back up on this phone')),
          const SizedBox(height: 24),
          const Text('Your company data is also kept on the BRV server: a new or replaced device receives it automatically when it is added. '
              'This file is an extra copy for your records.', style: muted),
        ]),
      );
}

class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});
  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    Db.q('SELECT a.*, u.name AS user FROM audit a LEFT JOIN users u ON u.id = a.user_id ORDER BY a.id DESC LIMIT 400').then((r) {
      if (mounted) setState(() => _rows = r);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Activity log')),
        body: _rows.isEmpty
            ? const Empty(Icons.history, 'Nothing yet.')
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: _rows.length,
                separatorBuilder: (_, __) => const Divider(),
                itemBuilder: (_, k) {
                  final a = _rows[k];
                  return ListTile(
                    dense: true,
                    title: Text('${s(a['user'])} · ${s(a['action']).replaceAll('_', ' ')}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('${dateText(a['date'])}\n${s(a['detail'])}'),
                  );
                },
              ),
      );
}
