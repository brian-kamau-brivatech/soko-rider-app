import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';

/// Before selling or handling money: a cashier must be signed in when Odoo
/// POS employee login is on. Opens the cashier screen if needed; true = ready.
Future<bool> ensureCashier(BuildContext context) async {
  if (!Store.i.needsCashier) return true;
  await Navigator.of(context).push<bool>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CashierScreen(popWhenDone: true)));
  return !Store.i.needsCashier;
}

/// "Log in to Shop": pick your name and enter your Odoo POS PIN, the same
/// people and PINs as the Odoo POS login screen (Select Cashier). Only the
/// selling part of the app (Sell, checkout, dispatch, session) asks for it.
class CashierScreen extends StatefulWidget {
  /// Opened before a money action: close itself once a cashier is signed in.
  final bool popWhenDone;
  const CashierScreen({super.key, this.popWhenDone = false});
  @override
  State<CashierScreen> createState() => _CashierScreenState();
}

class _CashierScreenState extends State<CashierScreen> {
  List<Cashier>? _list;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final (on, list) = await CashierApi.list(Store.i.pin);
      if (!mounted) return;
      if (!on) {
        await Store.i.checkCashiers(); // employee login was turned off in Odoo
        if (widget.popWhenDone && mounted) Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _list = list;
        _error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      if (e.auth) await Store.i.signOut();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _pick(Cashier c) async {
    String pin = '';
    if (c.hasPin) {
      final typed = await showDialog<String>(context: context, builder: (_) => _PinPad(name: c.name));
      if (typed == null) return;
      pin = typed;
    }
    setState(() => _busy = true);
    try {
      final (token, who) = await CashierApi.login(Store.i.pin, c.id, pin);
      await Store.i.setCashier(token, who.name.isEmpty ? c.name : who.name, who.role.isEmpty ? c.role : who.role);
      if (widget.popWhenDone && mounted) Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      backgroundColor: C.navy,
      body: SafeArea(
        child: Column(children: [
          if (widget.popWhenDone)
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(false),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            )
          else
            const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Image.asset('assets/logo.png', height: 52),
          ),
          const SizedBox(height: 18),
          Text('Log in to ${Store.i.shopName}', style: h(22, color: Colors.white)),
          const SizedBox(height: 4),
          const Text('Select your name, then enter your POS PIN', style: TextStyle(color: Color(0xFFC9D3E0))),
          const SizedBox(height: 18),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(color: C.bg, borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
              child: list == null
                  ? (_error != null
                      ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          EmptyNote(Icons.wifi_off_rounded, _error!),
                          TextButton(onPressed: _load, child: const Text('Try again')),
                        ])
                      : const Center(child: CircularProgressIndicator(color: C.green)))
                  : list.isEmpty
                      ? const EmptyNote(Icons.badge_outlined, 'No cashiers for this POS. Add employees in Odoo POS settings.')
                      : RefreshIndicator(
                          color: C.green,
                          onRefresh: _load,
                          child: GridView.builder(
                            padding: const EdgeInsets.all(16),
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 200,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 1.05,
                            ),
                            itemCount: list.length,
                            itemBuilder: (_, i) => _tile(list[i]),
                          ),
                        ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _tile(Cashier c) {
    final initials = c.name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).take(2).map((p) => p[0].toUpperCase()).join();
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: _busy ? null : () => _pick(c),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: C.line)),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: c.isManager ? C.navy : C.green,
              child: Text(initials.isEmpty ? '?' : initials, style: h(18, color: Colors.white)),
            ),
            const SizedBox(height: 10),
            Text(c.name, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: h(14.5)),
            const SizedBox(height: 2),
            Text(c.isManager ? 'Manager' : 'Cashier', style: const TextStyle(color: C.muted, fontSize: 12.5)),
          ]),
        ),
      ),
    );
  }
}

/// Number pad like the Odoo POS "Password?" box.
class _PinPad extends StatefulWidget {
  final String name;
  const _PinPad({required this.name});
  @override
  State<_PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<_PinPad> {
  String _pin = '';

  void _tap(String k) {
    setState(() {
      if (k == 'C') {
        _pin = '';
      } else if (k == '<') {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
      } else if (_pin.length < 12) {
        _pin += k;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', 'C', '0', '<'];
    return AlertDialog(
      title: Text(widget.name, style: h(18)),
      content: SizedBox(
        width: 280,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(12)),
            child: Text(_pin.isEmpty ? 'PIN' : '•' * _pin.length,
                style: h(24, color: _pin.isEmpty ? C.muted : C.ink).copyWith(letterSpacing: 6)),
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.6,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final k in keys)
                OutlinedButton(
                  onPressed: () => _tap(k),
                  style: OutlinedButton.styleFrom(foregroundColor: C.ink, side: const BorderSide(color: C.line), padding: EdgeInsets.zero),
                  child: k == '<' ? const Icon(Icons.backspace_outlined, size: 20) : Text(k, style: h(20)),
                ),
            ],
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Discard')),
        FilledButton(
          onPressed: _pin.isEmpty ? null : () => Navigator.pop(context, _pin),
          style: FilledButton.styleFrom(backgroundColor: C.green),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
