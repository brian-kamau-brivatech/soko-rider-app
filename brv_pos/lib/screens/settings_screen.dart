import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../db.dart';
import '../receipt.dart';
import '../sales.dart';
import '../session.dart';
import '../settings.dart';
import '../ui.dart';
import '../vscu.dart';
import 'calls_screen.dart';

class SettingsScreen extends StatefulWidget {
  final bool firstRun;
  const SettingsScreen({super.key, this.firstRun = false});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final s = Settings.i;
  late final _url = TextEditingController(text: s.vscuUrl);
  late final _tin = TextEditingController(text: s.tin);
  late final _bhf = TextEditingController(text: s.bhfId);
  late final _serial = TextEditingController(text: s.serial);
  late final _name = TextEditingController(text: s.businessName);
  late final _address = TextEditingController(text: s.address);
  late final _phone = TextEditingController(text: s.phone);
  late final _email = TextEditingController(text: s.email);
  late final _header = TextEditingController(text: s.header);
  late final _footer = TextEditingController(text: s.footer);

  bool _busy = false;
  String _conn = '';
  bool? _connOk;
  int _nextNo = 1;
  int _classes = 0;
  String _printerLabel = 'Automatic';

  @override
  void initState() {
    super.initState();
    _refreshNumbers();
    _loadPrinterLabel();
  }

  @override
  void dispose() {
    for (final c in [_url, _tin, _bhf, _serial, _name, _address, _phone, _email, _header, _footer]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _refreshNumbers() async {
    final n = await Db.nextInvoiceNo();
    final db = await Db.get();
    final c = (await db.rawQuery('SELECT COUNT(*) AS n FROM item_classes')).first['n'] as int? ?? 0;
    if (mounted) {
      setState(() {
        _nextNo = n;
        _classes = c;
      });
    }
  }

  Future<void> _loadPrinterLabel() async {
    final id = await Receipt.printerChoice();
    var label = id == 'auto' ? 'Automatic' : id == 'dialog' ? 'Android print screen (preview)' : id;
    if (id != 'auto' && id != 'dialog') {
      final info = await Receipt.printerInfo();
      for (final pr in (info['printers'] as List?) ?? const []) {
        if (pr is Map && pr['id'] == id) label = '${pr['label']}';
      }
    }
    if (mounted) setState(() => _printerLabel = label);
  }

  /// Copy what is typed into Settings (without saving yet).
  void _collect() {
    s.vscuUrl = _url.text.trim().replaceAll(RegExp(r'/+$'), '');
    // Keep only http(s)://host:port even if a full endpoint was pasted.
    final m = RegExp(r'^(https?://[^/]+)').firstMatch(s.vscuUrl);
    if (m != null) s.vscuUrl = m.group(1)!;
    s.tin = _tin.text.trim().toUpperCase();
    s.bhfId = _bhf.text.trim().padLeft(2, '0');
    s.serial = _serial.text.trim();
    s.businessName = _name.text.trim();
    s.address = _address.text.trim();
    s.phone = _phone.text.trim();
    s.email = _email.text.trim();
    s.header = _header.text.trim();
    s.footer = _footer.text.trim();
  }

  Future<void> _save() async {
    _collect();
    await s.save();
    if (!s.initialised) {
      // First save: connect the device to the VSCU so selling can start.
      await _initialise();
      return;
    }
    if (mounted) toast(context, 'Saved.');
  }

  Future<void> _testConnection() async {
    _collect();
    if (s.vscuUrl.isEmpty) {
      toast(context, 'Enter the VSCU address first.');
      return;
    }
    setState(() {
      _busy = true;
      _conn = 'Checking…';
      _connOk = null;
    });
    final (ok, msg) = await Vscu.ping(s.vscuUrl);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _conn = msg;
      _connOk = ok;
    });
  }

  Future<void> _initialise() async {
    _collect();
    final problems = <String>[
      if (!RegExp(r'^https?://').hasMatch(s.vscuUrl)) 'VSCU address, e.g. http://178.128.254.30:8088',
      if (!RegExp(r'^[A-Z]\d{9}[A-Z]$').hasMatch(s.tin)) 'KRA PIN (letter, 9 digits, letter)',
      if (!RegExp(r'^\d{2}$').hasMatch(s.bhfId)) 'Branch ID (2 digits)',
      if (s.serial.isEmpty) 'Device serial number',
    ];
    if (problems.isNotEmpty) {
      toast(context, 'Check: ${problems.join(', ')}');
      return;
    }
    if (s.initialised) {
      final again = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Check the device again?'),
          content: const Text('This asks the VSCU for the device details again. Your sales on this phone are kept.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Check')),
          ],
        ),
      );
      if (again != true) return;
    }
    setState(() => _busy = true);
    await s.save();
    final res = await Vscu.initialise();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!res.ok && Vscu.alreadyInstalled(res)) {
      // 902: the device was initialised before. It is set up: save and carry on.
      await _refreshNumbers();
      if (!mounted) return;
      toast(context, 'Device already initialised at KRA. Settings saved. Next invoice number: $_nextNo.');
      if (_classes == 0) Vscu.refreshItemClasses().then((_) => _refreshNumbers());
      return;
    }
    if (res.ok) {
      _name.text = s.businessName;
      _address.text = s.address;
      await _refreshNumbers();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.verified_rounded, color: C.green, size: 40),
          title: Text(s.taxpayerName.isEmpty ? 'Initialised' : s.taxpayerName),
          content: Text([
            'Branch ${s.bhfId}${s.branchName.isEmpty ? '' : ' · ${s.branchName}'}',
            if (s.location.isNotEmpty) s.location,
            if (s.deviceId.isNotEmpty) 'Device ID ${s.deviceId}',
            'Last invoice at KRA: ${s.lastSaleInvcNo ?? 0}',
            'Next invoice number: $_nextNo',
          ].join('\n')),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      // Load KRA item classifications in the background for the item picker.
      if (_classes == 0) Vscu.refreshItemClasses().then((_) => _refreshNumbers());
    } else {
      final msg = res.code == '901'
          ? 'KRA did not accept this device. Check the PIN, branch and device serial match the eTIMS portal exactly.'
          : res.message;
      final anyway = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.error_outline_rounded, color: C.red, size: 40),
          title: const Text('Could not confirm the device'),
          content: Text('$msg\n\nIf this device is already set up on your VSCU you can save anyway; '
              'every sale is still checked and signed by the VSCU.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save anyway')),
            FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Fix details')),
          ],
        ),
      );
      if (anyway == true) {
        s.initialised = true;
        await s.save();
      }
    }
  }

  Future<void> _pickLogo() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1200, maxHeight: 1200);
    if (x == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final dest = p.join(dir.path, 'logo_${DateTime.now().millisecondsSinceEpoch}${p.extension(x.path).isEmpty ? '.png' : p.extension(x.path)}');
    await File(x.path).copy(dest);
    final old = s.logoPath;
    s.logoPath = dest;
    await s.save();
    if (old.isNotEmpty && old != dest) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _removeLogo() async {
    final old = s.logoPath;
    s.logoPath = '';
    await s.save();
    try {
      if (old.isNotEmpty) await File(old).delete();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _changeNextNo() async {
    final c = TextEditingController(text: '$_nextNo');
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Next invoice number'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Change it only if KRA or the VSCU says a different number is expected. '
              'Numbers already used are refused, and skipped numbers leave gaps.'),
          const SizedBox(height: 12),
          TextField(controller: c, keyboardType: TextInputType.number, decoration: field('Next invoice number')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(c.text.trim())), child: const Text('Save')),
        ],
      ),
    );
    if (n == null || n < 1) return;
    await Db.setNextInvoiceNo(n);
    await _refreshNumbers();
    if (mounted) toast(context, 'Next invoice number is now $n.');
  }

  Future<void> _pickPrinter() async {
    final info = await Receipt.printerInfo();
    if (!mounted) return;
    final printers = ((info['printers'] as List?) ?? const []).whereType<Map>().toList();
    final current = await Receipt.printerChoice();
    if (!mounted) return;
    final options = <(String, String, String)>[
      ('auto', 'Automatic', printers.isEmpty ? 'No direct printer found: uses the print screen' : 'First printer that prints without a preview'),
      for (final pr in printers) ('${pr['id']}', '${pr['label']}', 'Prints straight away · ${pr['package']}'),
      ('dialog', 'Android print screen', 'Shows a preview first; also lets you pick Bluetooth or network printers'),
    ];
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Printer', style: h(18))),
          for (final o in options)
            ListTile(
              leading: Icon(current == o.$1 ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: current == o.$1 ? C.brand : C.muted),
              title: Text(o.$2, style: h(15, w: FontWeight.w700)),
              subtitle: Text(o.$3),
              onTap: () => Navigator.pop(ctx, o.$1),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (picked == null) return;
    await Receipt.setPrinterChoice(picked);
    await _loadPrinterLabel();
  }

  Future<void> _testPrint() async {
    _collect();
    await s.save();
    final now = DateTime.now();
    final sample = Sale({
      'id': 0, 'invc_no': 0, 'trd_invc_no': 'TEST-PRINT', 'kind': 'S', 'status': 'signed',
      'created_at': now.toIso8601String(), 'pmt_ty_cd': '01', 'tot_amt': 116.0, 'tot_tax': 16.0,
      'cashier': Session.i.name, 'payload': '{"taxblAmtB":100.0,"taxAmtB":16.0}',
      'sdc_id': s.controlUnitId.isEmpty ? 'KRACU0000000000' : s.controlUnitId, 'rcpt_no': 0, 'tot_rcpt_no': 0,
      'intrl_data': 'TESTPRINTNOTVALIDFORKRA000', 'rcpt_sign': 'TESTPRINTONLY000',
    }, [
      {'name': 'Test item (not a sale)', 'qty': 1, 'price': 116.0, 'tot': 116.0, 'dc_amt': 0, 'dc_rt': 0, 'tax': 'B'},
    ]);
    final png = await Receipt.image(sample, copy: true);
    final ok = await Receipt.printPng(png, 'BRV POS test');
    if (!mounted) return;
    toast(context, !ok
        ? 'Could not print.'
        : Receipt.lastMethod == 'dialog'
            ? 'Used the Android print screen. Pick your printer under Printer.'
            : 'Printed directly, no preview.');
  }

  Future<void> _loadClasses() async {
    setState(() => _busy = true);
    final res = await Vscu.refreshItemClasses();
    await _refreshNumbers();
    if (!mounted) return;
    setState(() => _busy = false);
    toast(context, res.ok ? 'Loaded $_classes KRA item classifications.' : res.message);
  }

  Widget _tf(TextEditingController c, String label,
          {String? hint, String? help, TextInputType? type, TextCapitalization caps = TextCapitalization.none, int lines = 1}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
        child: TextField(
          controller: c,
          keyboardType: type,
          textCapitalization: caps,
          maxLines: lines,
          decoration: field(label, hint: hint, help: help),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final logo = s.logoPath.isNotEmpty && File(s.logoPath).existsSync() ? File(s.logoPath) : null;
    return Scaffold(
      appBar: AppBar(title: Text(widget.firstRun ? 'Set up BRV POS' : 'Settings'), actions: [
        if (widget.firstRun)
          IconButton(tooltip: 'Sign out', onPressed: Session.i.signOut, icon: const Icon(Icons.logout_rounded)),
      ]),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 40), children: [
          if (widget.firstRun)
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(16)),
              child: const Text(
                'Enter your VSCU address and the device details registered on the KRA eTIMS portal, '
                'then tap Connect device (or Save). After that you can add items and start selling.',
                style: TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
              ),
            ),
          if (_busy) const LinearProgressIndicator(color: C.brand),

          Section('VSCU connection', [
            _tf(_url, 'VSCU address', hint: 'http://178.128.254.30:8088', type: TextInputType.url,
                help: 'Where your VSCU listens: http:// + server IP + : + port. No path.'),
            ListTile(
              leading: Icon(_connOk == null ? Icons.wifi_find_rounded : (_connOk! ? Icons.check_circle_rounded : Icons.error_rounded),
                  color: _connOk == null ? C.muted : (_connOk! ? C.green : C.red)),
              title: const Text('Test connection'),
              subtitle: _conn.isEmpty ? null : Text(_conn),
              onTap: _testConnection,
            ),
          ]),

          Section('Device', [
            _tf(_tin, 'KRA PIN', hint: 'P051638299E', caps: TextCapitalization.characters),
            _tf(_bhf, 'Branch ID', hint: '00', type: TextInputType.number, help: '00 is the head office.'),
            _tf(_serial, 'Device serial number', hint: 'TACT-CST-34-2024', help: 'Exactly as registered on the eTIMS portal.'),
            const SizedBox(height: 12),
            if (s.initialised)
              Container(
                margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: C.greenLight, borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.verified_rounded, color: C.green, size: 20),
                    const SizedBox(width: 6),
                    Expanded(child: Text('Device set up · live${s.taxpayerName.isEmpty ? '' : ' · ${s.taxpayerName}'}', style: h(14.5, color: C.green))),
                  ]),
                  const SizedBox(height: 4),
                  Text([
                    'Branch ${s.bhfId}${s.branchName.isEmpty ? '' : ' (${s.branchName})'}',
                    if (s.deviceId.isNotEmpty) 'Device ID ${s.deviceId}',
                    'SCU ID ${s.controlUnitId.isEmpty ? 'comes with the first sale' : s.controlUnitId}',
                  ].join(' · '), style: const TextStyle(color: C.ink, fontSize: 13)),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: SizedBox(
                height: 50,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _initialise,
                  icon: const Icon(Icons.power_settings_new_rounded),
                  label: Text(s.initialised ? 'Check device again' : 'Connect device'),
                  style: FilledButton.styleFrom(backgroundColor: s.initialised ? C.brand2 : C.green),
                ),
              ),
            ),
          ]),

          Section('Receipt', [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
              child: Row(children: [
                Container(
                  width: 120,
                  height: 72,
                  decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: C.line)),
                  alignment: Alignment.center,
                  child: logo == null
                      ? const Text('No logo', style: TextStyle(color: C.muted))
                      : Padding(padding: const EdgeInsets.all(6), child: Image.file(logo, fit: BoxFit.contain)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    OutlinedButton.icon(
                      onPressed: _pickLogo,
                      icon: const Icon(Icons.image_outlined),
                      label: Text(logo == null ? 'Add logo' : 'Change logo'),
                    ),
                    if (logo != null)
                      TextButton(onPressed: _removeLogo, child: const Text('Remove logo', style: TextStyle(color: C.red))),
                  ]),
                ),
              ]),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 4, 14, 0),
              child: Text('The logo prints in black and white on receipts and PDFs. A dark logo on white works best.',
                  style: TextStyle(color: C.muted, fontSize: 12.5)),
            ),
            _tf(_name, 'Business name on receipt', help: 'Filled from KRA at initialisation; you can change it.'),
            _tf(_address, 'Address'),
            _tf(_phone, 'Phone', type: TextInputType.phone),
            _tf(_email, 'Email', type: TextInputType.emailAddress),
            _tf(_header, 'Top message (optional)'),
            _tf(_footer, 'Bottom message', hint: 'Thank you for shopping with us!'),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(children: [
                const Expanded(child: Text('Paper width', style: TextStyle(fontWeight: FontWeight.w600))),
                SegmentedButton<int>(
                  segments: const [ButtonSegment(value: 58, label: Text('58 mm')), ButtonSegment(value: 80, label: Text('80 mm'))],
                  selected: {s.paperMm},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => setState(() => s.paperMm = v.first),
                ),
              ]),
            ),
          ]),

          Section('Printing', [
            ListTile(
              leading: const Icon(Icons.print_outlined, color: C.brand),
              title: const Text('Printer'),
              subtitle: Text(_printerLabel),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _pickPrinter,
            ),
            ListTile(
              leading: const Icon(Icons.receipt_rounded, color: C.brand),
              title: const Text('Test print'),
              subtitle: const Text('Prints a sample receipt with your logo (marked COPY).'),
              onTap: _testPrint,
            ),
          ]),

          if (s.initialised)
            Section('Invoice numbering', [
              ListTile(
                title: Text('Next invoice number: $_nextNo', style: h(16)),
                subtitle: Text('KRA\'s last invoice at initialisation was ${s.lastSaleInvcNo ?? 0}. '
                    'The number is used only when the VSCU signs a sale, so there are no gaps.'),
                trailing: TextButton(onPressed: _changeNextNo, child: const Text('Change')),
              ),
            ]),

          Section('KRA lists', [
            ListTile(
              leading: const Icon(Icons.category_outlined, color: C.brand),
              title: const Text('Item classifications'),
              subtitle: Text(_classes == 0 ? 'Not loaded yet' : '$_classes loaded from the VSCU'),
              trailing: TextButton(onPressed: s.initialised ? _loadClasses : null, child: const Text('Refresh')),
            ),
          ]),

          Section('More', [
            SwitchListTile(
              title: const Text('Send line prices VAT inclusive to eTIMS'),
              subtitle: const Text('On (recommended): unit price and line amount include VAT. '
                  'The taxable amount is always without VAT. Off: prices also sent without VAT.'),
              value: s.taxableInclVat,
              onChanged: (v) => setState(() => s.taxableInclVat = v),
            ),
            ListTile(
              leading: const Icon(Icons.history_rounded, color: C.brand),
              title: const Text('VSCU call log'),
              subtitle: const Text('Every request and reply, for support'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CallsScreen())),
            ),
          ]),

          SizedBox(
            height: 52,
            child: FilledButton(onPressed: _busy ? null : _save, child: Text(s.initialised ? 'Save settings' : 'Save & connect')),
          ),
        ]),
      ),
    );
  }
}
