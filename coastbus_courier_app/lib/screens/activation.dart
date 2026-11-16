import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api.dart';
import '../session.dart';
import '../sync.dart';
import '../ui.dart';

class ActivationScreen extends StatefulWidget {
  final bool revoked;
  const ActivationScreen({super.key, this.revoked = false});
  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _key = TextEditingController();
  bool _busy = false;
  String _err = '';

  Future<void> _go() async {
    final key = _key.text.trim();
    if (key.isEmpty) {
      setState(() => _err = 'Enter the activation key.');
      return;
    }
    setState(() {
      _busy = true;
      _err = '';
    });
    try {
      String uid = '';
      try {
        uid = await const MethodChannel('brv/print').invokeMethod<String>('deviceId') ?? '';
      } catch (_) {}
      final r = await Api.call('POST', '/activate', auth: false, body: {'key': key, 'device_uid': uid, 'model': 'Android handheld', 'app_version': '1.0'});
      await Sync.i.saveActivation('${r['token']}');
      await Sync.i.bootstrap();
      Session.i.lock();
      Sync.i.start();
    } on NetError catch (e) {
      setState(() => _err = e.message);
    } catch (e) {
      setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const SizedBox(height: 20),
          Center(child: ClipRRect(borderRadius: BorderRadius.circular(22), child: Image.asset('assets/app_icon.png', width: 96, height: 96))),
          const SizedBox(height: 14),
          Center(child: Text('Coast Bus Courier', style: h(26))),
          const SizedBox(height: 6),
          Text(
            widget.revoked
                ? 'This terminal was switched off or given a new key in Odoo. Ask the administrator for the activation key.'
                : 'Type the activation key for this terminal (Odoo: Courier → Configuration → Terminals).',
            textAlign: TextAlign.center,
            style: TextStyle(color: widget.revoked ? C.red : C.muted),
          ),
          const SizedBox(height: 22),
          TextField(
            controller: _key,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Activation key', hintText: 'e.g. 7KQ2MXRP'),
            onSubmitted: (_) => _go(),
          ),
          if (_err.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_err, style: const TextStyle(color: C.red, fontWeight: FontWeight.w700))),
          const SizedBox(height: 18),
          FilledButton(onPressed: _busy ? null : _go, child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : const Text('Activate')),
        ]),
      ),
    );
  }
}
