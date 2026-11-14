import 'package:flutter/material.dart';
import '../db.dart';
import '../fmt.dart';
import '../perms.dart';
import '../session.dart';
import '../settings.dart';
import '../ui.dart';

/// Several people share one phone: tap your name, type your PIN.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  List<Map<String, Object?>> _users = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final u = await Db.q('SELECT u.id, u.name, r.name AS role FROM users u JOIN roles r ON r.id = u.role_id WHERE u.active = 1 ORDER BY u.owner DESC, u.name');
    if (mounted) setState(() => _users = u);
  }

  Future<void> _pick(Map<String, Object?> u) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PinScreen(user: u)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 28, 20, 24), children: [
            Center(child: Image.asset('assets/brv_mark.png', height: 64)),
            const SizedBox(height: 12),
            Center(child: Text(Settings.i.businessName, style: h(24), textAlign: TextAlign.center)),
            const Center(child: Text('Who is using the app?', style: muted)),
            const SizedBox(height: 22),
            GridView.count(
              crossAxisCount: MediaQuery.of(context).size.width > 600 ? 4 : 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.85,
              children: [
                for (final u in _users)
                  InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _pick(u),
                    child: Container(
                      decoration: box(),
                      padding: const EdgeInsets.all(10),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Avatar(s(u['name']), size: 52, bg: C.ink, fg: Colors.white),
                        const SizedBox(height: 8),
                        Text(s(u['name']), style: h(14), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                        Text(s(u['role']), style: const TextStyle(color: C.muted, fontSize: 12), maxLines: 1),
                      ]),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 28),
            const Center(child: Text('BRV Pos Sales · by BRV Integrated Systems', style: TextStyle(color: C.muted, fontSize: 12))),
          ]),
        ),
      );
}

/// Number pad for the PIN.
class PinScreen extends StatefulWidget {
  final Map<String, Object?> user;
  const PinScreen({super.key, required this.user});
  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _pin = '';
  String _msg = '';
  bool _busy = false;

  Future<void> _press(String k) async {
    if (_busy) return;
    if (k == 'del') {
      setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1));
      return;
    }
    if (k == 'ok') {
      await _go();
      return;
    }
    if (_pin.length >= 6) return;
    setState(() {
      _pin += k;
      _msg = '';
    });
  }

  Future<void> _go() async {
    if (_pin.length < 4) {
      setState(() => _msg = 'Type your 4-6 digit PIN');
      return;
    }
    setState(() => _busy = true);
    final err = await Session.i.signIn(n(widget.user['id']), _pin);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _pin = '';
      _msg = err;
    });
  }

  Future<void> _forgot() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(title: const Text('Forgot your PIN?'), children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'manager'), child: const Padding(padding: EdgeInsets.all(6), child: Text('A manager resets it now (manager types their PIN)'))),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'code'), child: const Padding(padding: EdgeInsets.all(6), child: Text('Owner: use the recovery code'))),
      ]),
    );
    if (!mounted || choice == null) return;
    if (choice == 'manager') {
      final p = await ask(context, 'Manager PIN', label: 'PIN of someone allowed to manage users', number: true);
      if (p == null || !mounted) return;
      final m = await Session.userByPin(p.trim(), right: P.users);
      if (m == null) {
        if (mounted) toast(context, 'That is not the PIN of a user manager.');
        return;
      }
    } else {
      final owner = await Db.one('SELECT owner FROM users WHERE id = ?', [widget.user['id']]);
      if (n(owner?['owner']) != 1) {
        if (mounted) toast(context, 'The recovery code is only for the owner.');
        return;
      }
      final c = await ask(context, 'Recovery code', label: 'The code shown when the app was set up');
      if (c == null || !mounted) return;
      if (Session.hashPin(c.trim().toUpperCase(), 'recovery') != Settings.i.get('recovery_hash')) {
        toast(context, 'Wrong recovery code.');
        return;
      }
    }
    if (!mounted) return;
    final np = await ask(context, 'New PIN for ${widget.user['name']}', label: '4-6 digits', number: true);
    if (np == null || !mounted) return;
    if (!Session.pinOk(np.trim())) {
      toast(context, 'The PIN must be 4 to 6 digits.');
      return;
    }
    if (await Session.pinTaken(np.trim(), exceptId: n(widget.user['id']))) {
      if (mounted) toast(context, 'Someone else uses that PIN. Choose another.');
      return;
    }
    await Session.setPin(n(widget.user['id']), np.trim());
    if (mounted) toast(context, 'PIN changed. Sign in with the new PIN.');
  }

  Widget _key(String k) {
    final icon = k == 'del' ? Icons.backspace_outlined : (k == 'ok' ? Icons.arrow_forward_rounded : null);
    return Padding(
      padding: const EdgeInsets.all(7),
      child: Material(
        color: k == 'ok' ? C.ink : Colors.white,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _press(k),
          child: SizedBox(
            height: 64,
            child: Center(
              child: icon != null
                  ? Icon(icon, color: k == 'ok' ? Colors.white : C.ink)
                  : Text(k, style: h(26)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: SafeArea(
          child: Column(children: [
            Avatar(s(widget.user['name']), size: 64, bg: C.ink, fg: Colors.white),
            const SizedBox(height: 8),
            Text(s(widget.user['name']), style: h(20)),
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var k = 0; k < 6; k++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 7),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: k < _pin.length ? C.ink : Colors.transparent,
                    border: Border.all(color: k < 4 || k < _pin.length ? C.ink : C.line, width: 2),
                  ),
                ),
            ]),
            SizedBox(height: 34, child: Center(child: Text(_msg, style: const TextStyle(color: C.red, fontWeight: FontWeight.w600), textAlign: TextAlign.center))),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              child: Column(children: [
                for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9'], ['del', '0', 'ok']])
                  Row(children: [for (final k in row) Expanded(child: _key(k))]),
              ]),
            ),
            TextButton(onPressed: _forgot, child: const Text('Forgot PIN?')),
            const SizedBox(height: 8),
          ]),
        ),
      );
}
