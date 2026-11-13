import 'package:flutter/material.dart';
import '../api.dart';
import '../config.dart';
import '../store.dart';
import '../ui.dart';

/// First start (BRV technician): server address, device PIN, then which Point of Sale this handheld is.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _server = TextEditingController(text: Store.i.server);
  final _db = TextEditingController(text: Store.i.db);
  final _pin = TextEditingController();
  int _taps = 0;
  bool _busy = false;
  bool _advanced = AppConfig.defaultServer.isEmpty || Store.i.server.isEmpty;
  String? _error;
  List<PosConfigInfo>? _configs;

  @override
  void dispose() {
    _server.dispose();
    _db.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_server.text.trim().isEmpty || _pin.text.trim().length < 3) {
      setState(() => _error = _server.text.trim().isEmpty ? 'Enter the Odoo address (tap the logo 5 times).' : 'Enter a POS manager PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _configs = null;
    });
    try {
      await Store.i.setServer(_server.text, _db.text);
      final (_, configs) = await Store.i.checkDevice(_pin.text.trim());
      if (configs.isEmpty) {
        setState(() => _error = 'No Point of Sale is set up in Odoo.');
      } else if (configs.length == 1) {
        await Store.i.saveDevice(_pin.text.trim(), configs.first);
      } else {
        setState(() => _configs = configs);
      }
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.navy,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(children: [
                GestureDetector(
                  onTap: () {
                    _taps++;
                    if (_taps >= 5) setState(() => _advanced = true);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                    child: Image.asset('assets/brv_logo.png', height: 110),
                  ),
                ),
                const SizedBox(height: 12),
                Text(AppConfig.appName, style: h(28, color: Colors.white)),
                const Text('by BRV POS', style: TextStyle(color: C.gold, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text('Set up this handheld: a POS manager enters their PIN.',
                    textAlign: TextAlign.center, style: TextStyle(color: Color(0xFFC9D3E0), fontSize: 15)),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (_advanced)
                      TextField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                          labelText: 'Odoo address', hintText: 'https://utangevillage.example.co.ke', prefixIcon: Icon(Icons.link_rounded)),
                    ),
                    if (_advanced)
                      TextField(
                        controller: _db,
                        autocorrect: false,
                        decoration: const InputDecoration(labelText: 'Database', prefixIcon: Icon(Icons.storage_rounded)),
                      ),
                    TextField(
                      controller: _pin,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) => _check(),
                      decoration: const InputDecoration(labelText: 'POS manager PIN', prefixIcon: Icon(Icons.lock_rounded)),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: C.red, fontWeight: FontWeight.w600)),
                    ],
                    const SizedBox(height: 18),
                    primaryButton('Connect', _check, icon: Icons.login_rounded, busy: _busy),
                    if (_configs != null) ...[
                      const SizedBox(height: 18),
                      Text('Which Point of Sale is this handheld?', style: h(15)),
                      const SizedBox(height: 6),
                      for (final c in _configs!)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.storefront_rounded, color: C.green),
                          title: Text(c.name, style: h(15, w: FontWeight.w700)),
                          subtitle: Text(c.open ? 'Shift open' : 'Shift closed'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Store.i.saveDevice(_pin.text.trim(), c),
                        ),
                    ],
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
