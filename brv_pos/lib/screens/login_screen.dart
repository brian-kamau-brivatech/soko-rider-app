import 'package:flutter/material.dart';
import '../session.dart';
import '../ui.dart';
import 'users_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _hide = true;
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    FocusScope.of(context).unfocus();
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Enter your username and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final u = await Session.verify(_user.text, _pass.text);
    if (!mounted) return;
    if (u == null) {
      setState(() {
        _busy = false;
        _error = 'Wrong username or password.';
      });
      return;
    }
    if (u['first_login'] == 1) {
      // First sign-in: offer to change the username or password.
      final change = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.lock_reset_rounded, color: C.gold, size: 40),
          title: const Text('Welcome to BRV POS'),
          content: const Text('This is your first sign-in. Do you want to change your username or password now?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Change')),
          ],
        ),
      );
      if (!mounted) return;
      if (change == true) {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChangeCredentialsScreen(user: u)));
        if (!mounted) return;
      }
      await Session.markSeen(u['id'] as int);
    }
    // Load the latest row (the username may have changed).
    Session.i.signIn(u);
    await Session.i.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.brand,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
                  child: Image.asset('assets/brv_logo.png', height: 150, fit: BoxFit.contain),
                ),
                const SizedBox(height: 22),
                Text('BRV POS', textAlign: TextAlign.center, style: h(26, color: Colors.white)),
                const SizedBox(height: 4),
                const Text('KRA eTIMS point of sale', textAlign: TextAlign.center, style: TextStyle(color: C.gold, fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Sign in', style: h(20)),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _user,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: field('Username', prefix: const Icon(Icons.person_outline_rounded)),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pass,
                      obscureText: _hide,
                      onSubmitted: (_) => _signIn(),
                      decoration: field('Password', prefix: const Icon(Icons.lock_outline_rounded)).copyWith(
                        suffixIcon: IconButton(
                          icon: Icon(_hide ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                          onPressed: () => setState(() => _hide = !_hide),
                        ),
                      ),
                    ),
                    if (_error.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(_error, style: const TextStyle(color: C.red, fontWeight: FontWeight.w600)),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 54,
                      child: FilledButton(
                        onPressed: _busy ? null : _signIn,
                        child: _busy
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                            : Text('Sign in', style: h(17, color: Colors.white)),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 18),
                const Text('BRV Integrated Systems Limited',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 12.5)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
