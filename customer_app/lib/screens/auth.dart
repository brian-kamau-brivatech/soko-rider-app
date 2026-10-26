import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../config.dart';
import '../store.dart';
import '../ui.dart';
import 'shell.dart';

const _banner = '${AppConfig.baseUrl}/theme_soko/static/src/img/banner.jpg?v=2';

/// Sign in / Create account. Same look as Home: website banner photo on top,
/// clean white card below.
class AuthScreen extends StatefulWidget {
  /// true when shown on first launch (offers "Skip for now").
  final bool firstRun;
  final bool startWithSignUp;
  const AuthScreen({super.key, this.firstRun = false, this.startWithSignUp = true});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late bool _signUp = widget.startWithSignUp;
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _pin = TextEditingController();
  bool _showPin = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final s = AppStore.instance;
    _name.text = s.name;
    _phone.text = s.phone;
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _pin]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = _signUp
          ? await ShopApi.signUp(_name.text.trim(), _phone.text.trim(), _pin.text.trim())
          : await ShopApi.signIn(_phone.text.trim(), _pin.text.trim());
      await AppStore.instance.signedInWith(r);
      if (!mounted) return;
      _close();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        if (e.message.contains('already has an account')) _signUp = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _skip() async {
    await AppStore.instance.markAuthSeen();
    if (mounted) _close();
  }

  void _close() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop(true);
    } else {
      nav.pushReplacement(MaterialPageRoute(builder: (_) => const Shell()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: C.bg,
      body: SingleChildScrollView(
        child: Column(children: [
          // Photo header, like the Home banner.
          SizedBox(
            height: 270 + top,
            child: Stack(fit: StackFit.expand, children: [
              Container(color: C.greenDark),
              const NetImage(_banner, fit: BoxFit.cover),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x661C3E2C), Color(0xE61C3E2C)],
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(20, top + 12, 20, 44),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (!widget.firstRun) const BackSquare(),
                    const Spacer(),
                    if (widget.firstRun)
                      TextButton(
                        onPressed: _busy ? null : _skip,
                        style: TextButton.styleFrom(foregroundColor: Colors.white),
                        child: const Text('Skip for now', style: TextStyle(fontSize: 15)),
                      ),
                  ]),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                    child: Image.asset('assets/logo.png', height: 40),
                  ),
                  const SizedBox(height: 14),
                  Text.rich(TextSpan(children: [
                    TextSpan(text: _signUp ? 'Create your ' : 'Welcome ', style: head(26, color: Colors.white)),
                    TextSpan(text: _signUp ? 'account' : 'back', style: head(26, color: const Color(0xFF9BD46E))),
                  ])),
                  const SizedBox(height: 4),
                  Text(
                    _signUp ? 'Order fresh groceries and track every delivery.' : 'Sign in with your phone number and PIN.',
                    style: const TextStyle(color: Color(0xFFDCEBDD), fontSize: 14.5),
                  ),
                ]),
              ),
            ]),
          ),
          // White card overlapping the photo.
          Transform.translate(
            offset: const Offset(0, -28),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 24, offset: Offset(0, 8))],
              ),
              child: Form(
                key: _form,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _Tabs(signUp: _signUp, onChanged: (v) => setState(() {
                        _signUp = v;
                        _error = null;
                      })),
                  const SizedBox(height: 18),
                  if (_signUp) ...[
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      decoration: _dec('Full name', Icons.person_outline_rounded),
                      validator: (v) => v!.trim().length < 2 ? 'Enter your full name' : null,
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    decoration: _dec('Phone number', Icons.phone_outlined, hint: '0712 345 678'),
                    validator: (v) => v!.replaceAll(RegExp(r'[^0-9]'), '').length < 9 ? 'Enter your phone number' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pin,
                    keyboardType: TextInputType.number,
                    obscureText: !_showPin,
                    maxLength: 6,
                    onFieldSubmitted: (_) => _submit(),
                    decoration: _dec(_signUp ? 'Choose a PIN (4–6 digits)' : 'PIN', Icons.lock_outline_rounded).copyWith(
                      counterText: '',
                      suffixIcon: IconButton(
                        tooltip: _showPin ? 'Hide PIN' : 'Show PIN',
                        icon: Icon(_showPin ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: C.muted),
                        onPressed: () => setState(() => _showPin = !_showPin),
                      ),
                    ),
                    validator: (v) {
                      final t = v!.trim();
                      return (t.length < 4 || t.length > 6 || int.tryParse(t) == null) ? 'PIN must be 4 to 6 digits' : null;
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: const Color(0xFFFDECEC), borderRadius: BorderRadius.circular(12)),
                      child: Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 13.5)),
                    ),
                  ],
                  const SizedBox(height: 18),
                  PrimaryButton(_signUp ? 'Create account' : 'Sign in',
                      icon: Icons.arrow_forward_rounded, busy: _busy, onTap: _submit),
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton(
                      onPressed: _busy ? null : () => setState(() {
                            _signUp = !_signUp;
                            _error = null;
                          }),
                      style: TextButton.styleFrom(foregroundColor: C.green),
                      child: Text(_signUp ? 'Already have an account? Sign in' : 'New here? Create an account'),
                    ),
                  ),
                  if (!_signUp)
                    const Center(
                      child: Text('Forgot your PIN? Call the shop to reset it.',
                          style: TextStyle(fontSize: 12.5, color: C.muted)),
                    ),
                ]),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.lock_outline_rounded, size: 15, color: C.muted),
              SizedBox(width: 6),
              Flexible(
                child: Text('Your PIN is stored securely. We never ask for your M-Pesa PIN here.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: C.muted)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  InputDecoration _dec(String label, IconData icon, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 20, color: C.muted),
        fillColor: C.bg,
      );
}

class _Tabs extends StatelessWidget {
  final bool signUp;
  final ValueChanged<bool> onChanged;
  const _Tabs({required this.signUp, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    Widget tab(String label, bool value) {
      final on = signUp == value;
      return Expanded(
        child: InkWell(
          onTap: () => onChanged(value),
          borderRadius: BorderRadius.circular(11),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
              boxShadow: on ? const [BoxShadow(color: Color(0x14000000), blurRadius: 6)] : null,
            ),
            child: Text(label, style: head(14, w: FontWeight.w600, color: on ? C.green : C.muted)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: C.greenLight, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [tab('Sign in', false), tab('Create account', true)]),
    );
  }
}

/// Account page (signed in) — or the sign-in screen when signed out.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final s = AppStore.instance;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        if (!s.signedIn) return const AuthScreen(startWithSignUp: false);
        final initials = s.name.trim().isEmpty
            ? '?'
            : s.name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0].toUpperCase()).join();
        return Scaffold(
          body: SafeArea(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 10, 20, 24), children: [
              Row(children: [const BackSquare(), const SizedBox(width: 12), Text('My account', style: head(20))]),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: cardBox(),
                child: Row(children: [
                  Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: C.green, shape: BoxShape.circle),
                    child: Text(initials, style: head(19, color: Colors.white)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.name, style: head(17)),
                      Text(s.phone, style: const TextStyle(color: C.muted, fontSize: 14.5)),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: cardBox(),
                child: Column(children: [
                  _row(Icons.receipt_long_outlined, 'My orders', () {
                    Navigator.of(context).pop();
                    currentTab.value = 3;
                  }),
                  const Divider(height: 1, color: C.line, indent: 52),
                  _row(Icons.location_on_outlined, s.street.isEmpty ? 'No saved address yet' : s.street, null),
                  const Divider(height: 1, color: C.line, indent: 52),
                  _row(Icons.privacy_tip_outlined, 'Privacy policy',
                      () => launchUrl(Uri.parse('${AppConfig.siteUrl}/privacy'), mode: LaunchMode.externalApplication)),
                ]),
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await s.signOut();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Sign out'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFB91C1C),
                    side: const BorderSide(color: C.line),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => _confirmDelete(context),
                icon: const Icon(Icons.delete_forever_outlined, size: 20),
                label: const Text('Delete my account'),
                style: TextButton.styleFrom(foregroundColor: C.muted),
              ),
            ]),
          ),
        );
      },
    );
  }

  /// Delete the account: warn, ask for the PIN, then erase it on the server.
  Future<void> _confirmDelete(BuildContext context) async {
    final pin = TextEditingController();
    var busy = false;
    String? error;
    final done = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Delete your account?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('This erases your name, phone number, email, saved addresses and map pins, and signs you out. '
                'Past orders stay in our records without your details, as tax law requires. This cannot be undone.'),
            const SizedBox(height: 14),
            TextField(
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              enabled: !busy,
              decoration: const InputDecoration(labelText: 'Enter your PIN to confirm', counterText: '', border: OutlineInputBorder()),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: const TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.w600)),
            ],
          ]),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C)),
              onPressed: busy
                  ? null
                  : () async {
                      if (pin.text.trim().length < 4) {
                        setD(() => error = 'Enter your 4-6 digit PIN.');
                        return;
                      }
                      setD(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await ShopApi.deleteAccount(AppStore.instance.session, pin.text.trim());
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } on ApiError catch (e) {
                        setD(() {
                          busy = false;
                          error = e.message;
                        });
                      } catch (_) {
                        setD(() {
                          busy = false;
                          error = 'No connection. Try again.';
                        });
                      }
                    },
              child: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Delete'),
            ),
          ],
        ),
      ),
    );
    pin.dispose();
    if (done == true) {
      await AppStore.instance.signOut();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Your account has been deleted.')));
        Navigator.of(context).pop();
      }
    }
  }

  Widget _row(IconData icon, String label, VoidCallback? onTap) => ListTile(
        leading: Icon(icon, color: C.green),
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: onTap == null ? null : const Icon(Icons.chevron_right_rounded, color: C.muted),
        onTap: onTap,
      );
}
