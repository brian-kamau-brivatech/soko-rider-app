import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';

/// Shop device sign-in with the shop PIN set in Odoo.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_pin.text.trim().length < 4) {
      setState(() => _error = 'Enter the shop PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Store.i.signIn(_pin.text.trim());
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
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
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                  child: Image.asset('assets/logo.png', height: 52),
                ),
                const SizedBox(height: 22),
                Text('Soko Shop', style: h(28, color: Colors.white)),
                const SizedBox(height: 6),
                const Text('Incoming orders and riders for the shop counter.',
                    textAlign: TextAlign.center, style: TextStyle(color: Color(0xFFC9D3E0), fontSize: 15)),
                const SizedBox(height: 26),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Shop PIN', style: h(16)),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _pin,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: h(26).copyWith(letterSpacing: 10),
                      onSubmitted: (_) => _go(),
                      decoration: InputDecoration(
                        hintText: '••••',
                        filled: true,
                        fillColor: C.bg,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      Text(_error!, style: const TextStyle(color: C.red, fontWeight: FontWeight.w600)),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 54,
                      child: ElevatedButton(
                        onPressed: _busy ? null : _go,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: C.green,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: _busy
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                            : Text('Start receiving orders', style: h(16, color: Colors.white)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('The PIN is set by the manager in Odoo.',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: C.muted)),
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
