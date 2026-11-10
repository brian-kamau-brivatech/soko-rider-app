import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../licence.dart';
import '../ui.dart';

/// Licence: the device code to send to BRV, and where the key is pasted.
/// Reachable from the sign-in screen too, so a client can paste a renewal any time.
class LicenceScreen extends StatefulWidget {
  const LicenceScreen({super.key});
  @override
  State<LicenceScreen> createState() => _LicenceScreenState();
}

class _LicenceScreenState extends State<LicenceScreen> {
  final _key = TextEditingController();
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    Licence.i.addListener(_changed);
    Licence.i.refresh();
  }

  @override
  void dispose() {
    Licence.i.removeListener(_changed);
    _key.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) setState(() => _key.text = d!.text!);
  }

  Future<void> _activate() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    final err = await Licence.i.activate(_key.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err ?? '';
    });
    if (err == null) {
      _key.clear();
      toast(context, 'Licence activated. ${Licence.i.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = Licence.i;
    final good = l.state == LicState.ok;
    final soft = l.state == LicState.warn || l.state == LicState.trial;
    final fg = good ? C.green : (soft ? C.amber : C.red);
    final bg = good ? C.greenLight : (soft ? C.amberLight : C.redLight);
    return Scaffold(
      appBar: AppBar(title: const Text('Licence')),
      body: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 40), children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(good ? Icons.verified_rounded : (soft ? Icons.schedule_rounded : Icons.block_rounded), color: fg, size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(l.message, style: h(15, color: fg, w: FontWeight.w700))),
          ]),
        ),
        const SizedBox(height: 14),
        Section('This device', [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Device code', style: TextStyle(color: C.muted, fontWeight: FontWeight.w600)),
                  SelectableText(l.code, style: h(30, color: C.brand).copyWith(letterSpacing: 2)),
                ]),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: 'BRV POS licence request. Device code: ${l.code}'));
                  toast(context, 'Copied. Paste it in WhatsApp to BRV.');
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy'),
              ),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text('Send this code to BRV with the number of days paid. BRV sends back a licence key for this device only.',
                style: TextStyle(color: C.muted)),
          ),
        ]),
        Section('Activate a licence', [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
            child: TextField(
              controller: _key,
              minLines: 3,
              maxLines: 6,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: field('Licence key', help: 'Paste the whole message from BRV: the key is found in it.'),
            ),
          ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text(_error, style: const TextStyle(color: C.red, fontWeight: FontWeight.w600)),
            ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              OutlinedButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste_rounded), label: const Text('Paste')),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _activate,
                    icon: const Icon(Icons.key_rounded),
                    label: const Text('Activate licence'),
                  ),
                ),
              ),
            ]),
          ),
        ]),
        const Padding(
          padding: EdgeInsets.fromLTRB(6, 4, 6, 0),
          child: Text(
            'When the licence ends, selling stops until a new key is pasted. Receipts, reprints, reports and backups '
            'keep working. Renewals can be pasted here by the shop at any time.\n\n${Licence.contact}',
            style: TextStyle(color: C.muted, fontSize: 13),
          ),
        ),
      ]),
    );
  }
}

/// Asks for the BRV technician PIN (or creates it). Returns true when unlocked.
Future<bool> techUnlock(BuildContext context) async {
  if (Tech.unlocked) return true;
  final has = await Tech.hasPin();
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TechDialog(hasPin: has),
  );
  return ok == true && Tech.unlocked;
}

/// Change the technician PIN (only while unlocked).
Future<void> techChangePin(BuildContext context) async {
  if (!Tech.unlocked) return;
  await showDialog<bool>(context: context, builder: (_) => const _TechDialog(hasPin: true, changeOnly: true));
}

class _TechDialog extends StatefulWidget {
  final bool hasPin;
  final bool changeOnly;
  const _TechDialog({required this.hasPin, this.changeOnly = false});
  @override
  State<_TechDialog> createState() => _TechDialogState();
}

class _TechDialogState extends State<_TechDialog> {
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  final _key = TextEditingController();
  late String _mode; // enter | create | key
  String _error = '';
  bool _busy = false;
  bool _keyOk = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.changeOnly
        ? 'create'
        : widget.hasPin
            ? 'enter'
            : (Tech.freeSetup ? 'create' : 'key');
  }

  @override
  void dispose() {
    _pin.dispose();
    _pin2.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    String err = '';
    if (_mode == 'enter') {
      if (await Tech.checkPin(_pin.text)) {
        Tech.open();
      } else {
        err = 'Wrong technician PIN.';
      }
    } else if (_mode == 'key' && !_keyOk) {
      final e = await Tech.checkKey(_key.text);
      if (e == null) {
        _keyOk = true;
        _mode = 'create';
      } else {
        err = e;
      }
    } else {
      final p = _pin.text.trim();
      if (p.length < 4) {
        err = 'The PIN needs at least 4 characters.';
      } else if (p != _pin2.text.trim()) {
        err = 'The two PINs are not the same.';
      } else {
        await Tech.setPin(p);
        Tech.open();
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    if (err.isEmpty && Tech.unlocked && _mode != 'key') {
      if (widget.changeOnly) toast(context, 'Technician PIN changed.');
      Navigator.pop(context, true);
    } else if (err.isEmpty && _mode == 'create') {
      _pin.clear();
      _pin2.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (_mode) {
      'enter' => 'BRV technician PIN',
      'key' => 'Technician key',
      _ => widget.changeOnly ? 'New technician PIN' : 'Create the technician PIN',
    };
    final text = switch (_mode) {
      'enter' => 'KRA device and receipt header settings are for BRV only.',
      'key' => 'Make a technician key for device ${Licence.i.code} in the BRV Licence Maker '
          '(Technician key button) and paste it here. It is valid for 2 days.',
      _ => 'Only BRV should know this PIN. It unlocks the KRA device and receipt header settings for 15 minutes.',
    };
    return AlertDialog(
      icon: const Icon(Icons.admin_panel_settings_rounded, color: C.brand, size: 36),
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(text),
          const SizedBox(height: 12),
          if (_mode == 'key')
            TextField(
              controller: _key,
              minLines: 3,
              maxLines: 5,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              decoration: field('Technician key'),
            )
          else ...[
            TextField(
              controller: _pin,
              obscureText: true,
              autofocus: true,
              keyboardType: TextInputType.visiblePassword,
              onSubmitted: (_) => _mode == 'enter' ? _go() : null,
              decoration: field(_mode == 'enter' ? 'PIN' : 'New PIN'),
            ),
            if (_mode == 'create') ...[
              const SizedBox(height: 10),
              TextField(controller: _pin2, obscureText: true, keyboardType: TextInputType.visiblePassword, decoration: field('Repeat the PIN')),
            ],
          ],
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_error, style: const TextStyle(color: C.red, fontWeight: FontWeight.w600)),
          ],
          if (_mode == 'enter')
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() {
                  _mode = 'key';
                  _error = '';
                }),
                child: const Text('Forgot the PIN? Use a technician key'),
              ),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _go,
          child: Text(_mode == 'enter' ? 'Unlock' : (_mode == 'key' ? 'Check key' : 'Save PIN')),
        ),
      ],
    );
  }
}
