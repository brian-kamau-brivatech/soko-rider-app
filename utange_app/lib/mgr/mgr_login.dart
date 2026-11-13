import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';

/// Manager sign-in with their own Odoo user (POS or Inventory manager).
class MgrLogin extends StatefulWidget {
  const MgrLogin({super.key});
  @override
  State<MgrLogin> createState() => _MgrLoginState();
}

class _MgrLoginState extends State<MgrLogin> {
  final _server = TextEditingController(text: Store.i.server);
  final _db = TextEditingController(text: Store.i.db);
  final _login = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _showServer = Store.i.server.isEmpty;
  int _taps = 0;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _db.dispose();
    _login.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_server.text.trim().isEmpty || _login.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Enter the Odoo address, your username and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Store.i.setServer(_server.text, _db.text);
      await Store.i.managerSignIn(_login.text, _pass.text);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message.contains('denied') || e.message.contains('Access') ? 'Wrong username or password.' : e.message);
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
                    if (_taps >= 5) setState(() => _showServer = true);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                    child: Image.asset('assets/brv_logo.png', height: 110),
                  ),
                ),
                const SizedBox(height: 12),
                Text('Utange Manager', style: h(28, color: Colors.white)),
                const Text('by BRV POS', style: TextStyle(color: C.gold, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text('Requests, shifts and stock sheets.', style: TextStyle(color: Color(0xFFC9D3E0), fontSize: 15)),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (_showServer) ...[
                      TextField(
                        controller: _server,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(labelText: 'Odoo address', prefixIcon: Icon(Icons.link_rounded)),
                      ),
                      TextField(
                        controller: _db,
                        autocorrect: false,
                        decoration: const InputDecoration(labelText: 'Database', prefixIcon: Icon(Icons.storage_rounded)),
                      ),
                    ],
                    TextField(
                      controller: _login,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Odoo username (email)', prefixIcon: Icon(Icons.person_rounded)),
                    ),
                    TextField(
                      controller: _pass,
                      obscureText: true,
                      onSubmitted: (_) => _go(),
                      decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_rounded)),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: C.red, fontWeight: FontWeight.w600)),
                    ],
                    const SizedBox(height: 18),
                    primaryButton('Sign in', _go, icon: Icons.login_rounded, busy: _busy),
                    const SizedBox(height: 10),
                    const Text('For POS and Inventory managers. Same login as Odoo.',
                        textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 12.5)),
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
