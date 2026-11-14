import 'package:flutter/material.dart';
import '../db.dart';
import '../fmt.dart';
import '../session.dart';
import '../settings.dart';
import '../ui.dart';

/// First start: the business and the owner (the first user, with every right).
class SetupScreen extends StatefulWidget {
  final VoidCallback onDone;
  const SetupScreen({super.key, required this.onDone});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _business = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _pinNo = TextEditingController();
  final _owner = TextEditingController();
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  bool _vat = true;
  bool _busy = false;

  Future<void> _save() async {
    final pin = _pin.text.trim();
    if (_business.text.trim().isEmpty || _owner.text.trim().isEmpty) {
      toast(context, 'Enter the business name and your name.');
      return;
    }
    if (!Session.pinOk(pin)) {
      toast(context, 'The PIN must be 4 to 6 digits.');
      return;
    }
    if (pin != _pin2.text.trim()) {
      toast(context, 'The two PINs are not the same.');
      return;
    }
    setState(() => _busy = true);
    try {
      final st = Settings.i;
      await st.set('business_name', _business.text.trim());
      await st.set('phone', _phone.text.trim());
      await st.set('address', _address.text.trim());
      await st.set('tax_pin', _pinNo.text.trim().toUpperCase());
      await st.setFlag('vat_registered', _vat);
      final role = await Db.one("SELECT id FROM roles WHERE name = 'Owner'");
      final uid = await Session.createUser(name: _owner.text.trim(), pin: pin, roleId: n(role?['id']), owner: true);
      final code = Session.newRecoveryCode();
      await st.set('recovery_hash', Session.hashPin(code, 'recovery'));
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Write down your recovery code'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('If you (the owner) ever forget your PIN, this code lets you set a new one. Keep it somewhere safe. It is shown only now.'),
            const SizedBox(height: 16),
            Center(child: SelectableText(code, style: h(26).copyWith(letterSpacing: 3))),
          ]),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), style: FilledButton.styleFrom(minimumSize: const Size(0, 42)), child: const Text('I wrote it down'))],
        ),
      );
      await Session.i.signIn(uid, pin);
      widget.onDone();
    } catch (e) {
      if (mounted) toast(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 32), children: [
            Center(child: Image.asset('assets/brv_logo.png', height: 120)),
            const SizedBox(height: 8),
            Center(child: Text('BRV Pos Sales', style: h(26))),
            const Center(child: Text('Set up your business. Everything stays on this phone and works offline.', textAlign: TextAlign.center, style: muted)),
            const Label('Business'),
            TextField(controller: _business, decoration: const InputDecoration(labelText: 'Business name *')),
            const SizedBox(height: 10),
            TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
            const SizedBox(height: 10),
            TextField(controller: _address, decoration: const InputDecoration(labelText: 'Address / location')),
            const SizedBox(height: 10),
            TextField(controller: _pinNo, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'KRA PIN (optional, printed on receipts)')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _vat,
              onChanged: (v) => setState(() => _vat = v),
              title: const Text('VAT registered'),
              subtitle: const Text('Prices include VAT; VAT is shown on receipts and in the accounts.'),
            ),
            const Label('You (the owner)'),
            TextField(controller: _owner, decoration: const InputDecoration(labelText: 'Your name *')),
            const SizedBox(height: 10),
            TextField(controller: _pin, obscureText: true, keyboardType: TextInputType.number, maxLength: 6, decoration: const InputDecoration(labelText: 'Your PIN (4-6 digits) *', counterText: '')),
            const SizedBox(height: 10),
            TextField(controller: _pin2, obscureText: true, keyboardType: TextInputType.number, maxLength: 6, decoration: const InputDecoration(labelText: 'Repeat the PIN *', counterText: '')),
            const SizedBox(height: 20),
            FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving...' : 'Start')),
            const SizedBox(height: 12),
            const Center(child: Text('Restoring from a backup? Start, then More > Backup and restore.', style: muted, textAlign: TextAlign.center)),
          ]),
        ),
      );
}
