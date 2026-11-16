import 'dart:async';
import 'package:flutter/material.dart';
import '../api.dart';
import '../codes.dart';
import '../db.dart';
import '../docs.dart';
import '../fare.dart';
import '../fmt.dart';
import '../master.dart';
import '../ops.dart';
import '../printer.dart';
import '../scanner.dart';
import '../session.dart';
import '../sync.dart';
import '../ui.dart';

/// Counter intake: parcel details → charge → payment → receipt + one label per piece.
class BookScreen extends StatefulWidget {
  const BookScreen({super.key});
  @override
  State<BookScreen> createState() => _BookScreenState();
}

class _BookScreenState extends State<BookScreen> {
  final _sName = TextEditingController(), _sPhone = TextEditingController(), _sId = TextEditingController();
  final _rName = TextEditingController(), _rPhone = TextEditingController();
  final _desc = TextEditingController(), _weight = TextEditingController(), _pieces = TextEditingController(text: '1');
  final _l = TextEditingController(), _w = TextEditingController(), _h = TextEditingController(), _declared = TextEditingController();
  final _note = TextEditingController();
  int _dest = 0;
  bool _insured = false, _fragile = false, _dims = false, _preprinted = false;
  String _label = '';

  @override
  void initState() {
    super.initState();
    final dests = Master.i.destinations();
    if (dests.length == 1) _dest = n(dests.first['id']);
    _sPhone.addListener(() => _fill(_sPhone, _sName, 'sender'));
    _rPhone.addListener(() => _fill(_rPhone, _rName, 'receiver'));
  }

  /// Regular customers: the name comes back from the last parcel with that phone.
  Future<void> _fill(TextEditingController phone, TextEditingController name, String who) async {
    final p = normPhone(phone.text);
    if (!phoneOk(p) || name.text.isNotEmpty) return;
    final r = await Db.waybills('${who}_phone = ?', [p], 'booked_at DESC', 1);
    if (r.isNotEmpty && name.text.isEmpty && mounted) setState(() => name.text = s(r.first['${who}_name']));
  }

  Fare? get _fare => _dest == 0
      ? null
      : Fare.compute(
          origin: Master.i.hubId, dest: _dest, weight: d(_weight.text), l: _dims ? d(_l.text) : 0, w: _dims ? d(_w.text) : 0, h: _dims ? d(_h.text) : 0,
          declared: d(_declared.text), insured: _insured, pieces: n(_pieces.text) < 1 ? 1 : n(_pieces.text));

  String? _check() {
    if (_dest == 0) return 'Choose the destination.';
    if (_sName.text.trim().isEmpty || !phoneOk(_sPhone.text)) return 'Enter the sender name and a valid phone.';
    if (_rName.text.trim().isEmpty || !phoneOk(_rPhone.text)) return 'Enter the receiver name and a valid phone.';
    if (_desc.text.trim().isEmpty) return 'Describe the contents.';
    if (d(_weight.text) <= 0) return 'Enter the weight.';
    if (n(_pieces.text) < 1) return 'Pieces must be at least 1.';
    if (_insured && d(_declared.text) <= 0) return 'Enter the declared value to insure.';
    if (_preprinted && _label.isEmpty) return 'Scan the pre-printed label.';
    if (_fare == null) return 'No tariff from ${Master.i.hubName} to ${Master.i.hubLabel(_dest)}. Add it in Odoo.';
    return null;
  }

  Future<void> _next() async {
    final err = _check();
    if (err != null) {
      toast(context, err, bad: true);
      return;
    }
    final f = _fare!;
    final w = <String, dynamic>{
      if (_preprinted) 'name': _label,
      'destination_hub_id': _dest, 'sender_name': _sName.text.trim(), 'sender_phone': normPhone(_sPhone.text), 'sender_id_no': _sId.text.trim(),
      'receiver_name': _rName.text.trim(), 'receiver_phone': normPhone(_rPhone.text), 'description': _desc.text.trim(),
      'pieces': n(_pieces.text), 'weight': d(_weight.text), 'length': _dims ? d(_l.text) : 0, 'width': _dims ? d(_w.text) : 0, 'height': _dims ? d(_h.text) : 0,
      'declared_value': d(_declared.text), 'insured': _insured, 'fragile': _fragile, 'vol_weight': f.volWeight, 'chargeable_weight': f.chargeable,
      'fare': f.fare, 'insurance': f.insurance, 'total': f.total, 'vat_amount': f.vat, 'note': _note.text.trim(),
    };
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayScreen(w: w)));
  }

  Future<void> _scanLabel() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const CameraScan()));
    if (code == null) return;
    final c = await parseCode(code);
    setState(() => _label = c.isWaybill ? c.name : code.trim().toUpperCase());
  }

  @override
  Widget build(BuildContext context) {
    final dests = Master.i.destinations();
    final f = _fare;
    Widget field(TextEditingController c, String label, {TextInputType? type, bool caps = false, int flex = 1}) => Expanded(
          flex: flex,
          child: TextField(
            controller: c,
            keyboardType: type,
            textCapitalization: caps ? TextCapitalization.words : TextCapitalization.sentences,
            decoration: InputDecoration(labelText: label),
            onChanged: (_) => setState(() {}),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Book parcel')),
      body: ListView(padding: const EdgeInsets.fromLTRB(14, 6, 14, 120), children: [
        const Label('Destination'),
        if (dests.isEmpty) const Empty(Icons.alt_route, 'No routes with a tariff from this branch. Add them in Odoo: Courier → Configuration → Routes & tariffs.'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final h in dests)
            ChoiceChip(
              label: Text('${h['name']} (${h['code']})', style: const TextStyle(fontWeight: FontWeight.w700)),
              selected: _dest == n(h['id']),
              onSelected: (_) => setState(() => _dest = n(h['id'])),
            ),
        ]),
        const Label('Sender'),
        Row(children: [field(_sPhone, 'Phone', type: TextInputType.phone), const SizedBox(width: 8), field(_sName, 'Name', caps: true, flex: 2)]),
        const SizedBox(height: 8),
        Row(children: [field(_sId, 'ID no. (optional)', type: TextInputType.number)]),
        const Label('Receiver'),
        Row(children: [field(_rPhone, 'Phone', type: TextInputType.phone), const SizedBox(width: 8), field(_rName, 'Name', caps: true, flex: 2)]),
        const Label('Parcel'),
        Row(children: [field(_desc, 'Contents', flex: 3)]),
        const SizedBox(height: 8),
        Row(children: [
          field(_weight, 'Weight (kg)', type: const TextInputType.numberWithOptions(decimal: true)),
          const SizedBox(width: 8),
          field(_pieces, 'Pieces', type: TextInputType.number),
        ]),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: _dims, onChanged: (v) => setState(() => _dims = v), title: const Text('Bulky: enter size (volumetric weight)')),
        if (_dims)
          Row(children: [
            field(_l, 'L cm', type: TextInputType.number),
            const SizedBox(width: 8),
            field(_w, 'W cm', type: TextInputType.number),
            const SizedBox(width: 8),
            field(_h, 'H cm', type: TextInputType.number),
          ]),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: _fragile, onChanged: (v) => setState(() => _fragile = v), title: const Text('Fragile')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _insured,
          onChanged: (v) => setState(() => _insured = v),
          title: const Text('Insure'),
          subtitle: Text('${Master.i.num_('insurance_pct')}% of the declared value'),
        ),
        Row(children: [field(_declared, _insured ? 'Declared value (KES)' : 'Declared value (optional)', type: TextInputType.number)]),
        const SizedBox(height: 8),
        Row(children: [field(_note, 'Note (optional)')]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _preprinted,
          onChanged: (v) => setState(() => _preprinted = v),
          title: const Text('Use a pre-printed label'),
          subtitle: Text(_preprinted ? (_label.isEmpty ? 'Scan the label stuck on the parcel' : 'Label: $_label') : 'Off: the terminal gives the number and prints labels'),
        ),
        if (_preprinted)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ScanBar(hint: 'Scan the pre-printed label', onCode: (raw) async {
              final c = await parseCode(raw);
              setState(() => _label = c.isWaybill ? c.name : raw.trim().toUpperCase());
              Scanner.good();
            }),
          ),
      ]),
      bottomSheet: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: C.line))),
        child: SafeArea(
          top: false,
          child: Row(children: [
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(f == null ? 'KES —' : money(f.total), style: h(24)),
                Text(f == null ? 'Choose destination and weight' : 'Chargeable ${kg(f.chargeable)}${f.insurance > 0 ? ' · insurance ${money(f.insurance)}' : ''}',
                    style: const TextStyle(color: C.muted, fontSize: 12.5)),
              ]),
            ),
            FilledButton.icon(onPressed: _next, icon: const Icon(Icons.payments_outlined), label: const Text('Payment')),
          ]),
        ),
      ),
    );
  }
}

/// Payment: cash / M-Pesa code / M-Pesa STK / account, then save, receipt and labels.
class PayScreen extends StatefulWidget {
  final Map<String, dynamic> w;
  const PayScreen({super.key, required this.w});
  @override
  State<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends State<PayScreen> {
  String _mode = '';
  final _given = TextEditingController();
  final _code = TextEditingController();
  final _stkPhone = TextEditingController();
  Map<String, dynamic>? _account;
  String _stkState = '';
  String _stkReceipt = '';
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    final m = Master.i;
    final modes = [if (m.flag('pay_cash')) 'cash', if (m.flag('pay_mpesa_code')) 'mpesa_code', if (m.flag('pay_mpesa_stk')) 'mpesa_stk', if (m.flag('pay_account')) 'account'];
    _mode = modes.isEmpty ? 'cash' : modes.first;
    _stkPhone.text = localPhone(s(widget.w['sender_phone']));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  double get _total => d(widget.w['total']);

  Future<void> _stk() async {
    setState(() {
      _busy = true;
      _stkState = 'sending';
    });
    try {
      final r = await Api.call('POST', '/mpesa/stk', body: {'phone': normPhone(_stkPhone.text), 'amount': _total, 'ref': 'COURIER', 'staff_id': Session.i.id});
      final id = r['id'];
      setState(() => _stkState = 'pending');
      var waited = 0;
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 3), (t) async {
        waited += 3;
        try {
          final st = await Api.call('GET', '/mpesa/status', query: {'id': '$id'});
          if (st['state'] == 'paid') {
            t.cancel();
            setState(() {
              _stkState = 'paid';
              _stkReceipt = s(st['receipt']);
            });
            Scanner.good();
          } else if (st['state'] == 'failed') {
            t.cancel();
            setState(() => _stkState = 'failed: ${st['desc']}');
            Scanner.bad();
          }
        } catch (_) {}
        if (waited > 120 && t.isActive) {
          t.cancel();
          setState(() => _stkState = 'failed: no answer from M-Pesa. Try again or take the M-Pesa code.');
        }
      });
    } on NetError catch (e) {
      setState(() => _stkState = 'failed: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _check() {
    switch (_mode) {
      case 'cash':
        if (_given.text.isNotEmpty && d(_given.text) < _total) return 'Cash given is less than the total.';
      case 'mpesa_code':
        final c = _code.text.trim().toUpperCase();
        if (!RegExp(r'^[A-Z0-9]{10}$').hasMatch(c)) return 'Enter the 10-character M-Pesa code.';
      case 'mpesa_stk':
        if (_stkState != 'paid') return 'Wait for the M-Pesa payment to complete.';
      case 'account':
        if (_account == null) return 'Choose the account customer.';
    }
    return null;
  }

  Future<void> _save() async {
    final err = _check();
    if (err != null) {
      toast(context, err, bad: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final w = await Ops.book({
        ...widget.w,
        'payment_mode': _mode,
        'payment_ref': _mode == 'mpesa_code' ? _code.text.trim().toUpperCase() : (_mode == 'mpesa_stk' ? _stkReceipt : ''),
        if (_mode == 'account') 'account_partner_id': _account!['id'],
        if (_mode == 'account') 'account_name': _account!['name'],
      });
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => BookedScreen(w: w)));
    } catch (e) {
      if (mounted) toast(context, '$e'.replaceFirst('Exception: ', ''), bad: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = Master.i;
    final w = widget.w;
    final modes = <(String, String, IconData)>[
      if (m.flag('pay_cash')) ('cash', 'Cash', Icons.payments_outlined),
      if (m.flag('pay_mpesa_code')) ('mpesa_code', 'M-Pesa code', Icons.sms_outlined),
      if (m.flag('pay_mpesa_stk')) ('mpesa_stk', 'M-Pesa prompt', Icons.phone_android),
      if (m.flag('pay_account') && m.accounts.isNotEmpty) ('account', 'Account', Icons.business_outlined),
    ];
    final change = d(_given.text) - _total;
    return Scaffold(
      appBar: AppBar(title: const Text('Payment')),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: box(color: C.ink, border: false),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${m.hubCode} → ${m.hubLabel(n(w['destination_hub_id']))}', style: const TextStyle(color: Color(0xFFCBD5E1), fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(money(_total), style: h(32, color: Colors.white)),
            Text('${w['pieces']} pc · ${kg(d(w['chargeable_weight']))} chargeable · ${w['description']}', style: const TextStyle(color: Color(0xFFCBD5E1))),
            if (d(w['insurance']) > 0) Text('Freight ${money(d(w['fare']))} + insurance ${money(d(w['insurance']))}', style: const TextStyle(color: Color(0xFFCBD5E1))),
          ]),
        ),
        const Label('How is the customer paying?'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final x in modes)
            ChoiceChip(
              avatar: Icon(x.$3, size: 18),
              label: Text(x.$2, style: const TextStyle(fontWeight: FontWeight.w700)),
              selected: _mode == x.$1,
              onSelected: _stkState == 'pending' ? null : (_) => setState(() => _mode = x.$1),
            ),
        ]),
        const SizedBox(height: 14),
        if (_mode == 'cash') ...[
          TextField(controller: _given, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Cash given (optional)'), onChanged: (_) => setState(() {})),
          if (_given.text.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(change >= 0 ? 'Change: ${money(change)}' : 'Short by ${money(-change)}', style: h(20, color: change >= 0 ? C.green : C.red))),
        ],
        if (_mode == 'mpesa_code')
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            maxLength: 10,
            decoration: const InputDecoration(labelText: 'M-Pesa code from the customer\'s SMS', hintText: 'e.g. QKJ82910XS'),
          ),
        if (_mode == 'mpesa_stk') ...[
          TextField(controller: _stkPhone, keyboardType: TextInputType.phone, enabled: _stkState != 'pending' && _stkState != 'paid', decoration: const InputDecoration(labelText: 'Customer M-Pesa phone')),
          const SizedBox(height: 10),
          if (_stkState == 'pending')
            const ListTile(leading: CircularProgressIndicator(), title: Text('Waiting for the customer to enter their M-Pesa PIN…'))
          else if (_stkState == 'paid')
            ListTile(leading: const Icon(Icons.check_circle, color: C.green, size: 36), title: Text('Paid · $_stkReceipt', style: h(17, color: C.green)))
          else ...[
            if (_stkState.startsWith('failed')) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_stkState.substring(8), style: const TextStyle(color: C.red, fontWeight: FontWeight.w700))),
            OutlinedButton.icon(onPressed: _busy ? null : _stk, icon: const Icon(Icons.send_to_mobile), label: Text('Send prompt for ${money(_total)}')),
            const Text('Needs the internet.', style: TextStyle(color: C.muted, fontSize: 12.5)),
          ],
        ],
        if (_mode == 'account')
          DropdownButtonFormField<int>(
            value: _account == null ? null : n(_account!['id']),
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Account customer (billed on invoice)'),
            items: [for (final a in m.accounts) DropdownMenuItem(value: n(a['id']), child: Text(s(a['name'])))],
            onChanged: (v) => setState(() => _account = m.accounts.firstWhere((a) => n(a['id']) == v)),
          ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.print),
          label: Text(_mode == 'account' ? 'Save, print receipt & labels' : 'Paid · print receipt & labels'),
        ),
      ]),
    );
  }
}

/// Booked: prints the receipt and one label per piece; reprint options.
class BookedScreen extends StatefulWidget {
  final Map<String, dynamic> w;
  const BookedScreen({super.key, required this.w});
  @override
  State<BookedScreen> createState() => _BookedScreenState();
}

class _BookedScreenState extends State<BookedScreen> {
  String _msg = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _printAll());
  }

  Future<void> _printAll() async {
    setState(() => _msg = 'Printing receipt…');
    var ok = await Printer.print(Docs.receipt(widget.w), 'Receipt ${widget.w['name']}');
    final pcs = n(widget.w['pieces']) < 1 ? 1 : n(widget.w['pieces']);
    for (var p = 1; p <= pcs; p++) {
      if (!mounted) return;
      setState(() => _msg = 'Printing label $p of $pcs…');
      ok = await Printer.print(Docs.sticker(widget.w, p), 'Label ${widget.w['name']} $p') && ok;
    }
    if (mounted) setState(() => _msg = ok ? 'Printed. Stick one label on each piece.' : 'Printer problem (${Printer.lastMethod}). Use the buttons below to print again.');
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.w;
    final pcs = n(w['pieces']) < 1 ? 1 : n(w['pieces']);
    return Scaffold(
      appBar: AppBar(title: const Text('Booked'), automaticallyImplyLeading: false),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Icon(Icons.check_circle, color: C.green, size: 72),
        const SizedBox(height: 8),
        Center(child: Text(s(w['name']), style: h(26))),
        Center(child: Text('${Master.i.hubCode} → ${Master.i.hubLabel(n(w['destination_hub_id']))} · ${money(d(w['total']))}', style: const TextStyle(color: C.muted))),
        const SizedBox(height: 10),
        Center(child: Text(_msg, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700))),
        const SizedBox(height: 4),
        Center(
          child: Text(Sync.i.online ? 'The sender gets an SMS with the tracking link.' : 'Offline: saved on the terminal, sent to Odoo (and SMS) when back online.',
              textAlign: TextAlign.center, style: const TextStyle(color: C.muted, fontSize: 12.5)),
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(onPressed: () => Printer.print(Docs.receipt(w, copy: true), 'Receipt copy'), icon: const Icon(Icons.receipt), label: const Text('Print receipt again')),
        const SizedBox(height: 8),
        for (var p = 1; p <= pcs; p++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton.icon(onPressed: () => Printer.print(Docs.sticker(w, p), 'Label $p'), icon: const Icon(Icons.qr_code_2), label: Text('Print label $p of $pcs')),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () {
            final nav = Navigator.of(context);
            nav.popUntil((r) => r.isFirst);
            nav.push(MaterialPageRoute(builder: (_) => const BookScreen()));
          },
          icon: const Icon(Icons.add),
          label: const Text('Next parcel'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst), child: const Text('Done')),
      ]),
    );
  }
}
