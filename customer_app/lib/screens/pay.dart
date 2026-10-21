import 'dart:async';
import 'package:flutter/material.dart';
import '../api.dart';
import '../ui.dart';
import 'track.dart';

/// Sends the M-Pesa prompt and waits until the payment is confirmed.
class PayScreen extends StatefulWidget {
  final ShopOrder order;
  final String phone;
  const PayScreen({super.key, required this.order, required this.phone});
  @override
  State<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends State<PayScreen> {
  late String _phone;
  bool _sending = false;
  bool _sent = false;
  bool _checking = false;
  String? _error;
  Timer? _poll;
  Timer? _tick;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _phone = widget.phone;
    WidgetsBinding.instance.addPostFrameCallback((_) => _send());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _check(silent: true));
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _sent) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ShopApi.pay(widget.order.id, widget.order.token, _phone);
      if (!mounted) return;
      setState(() {
        _sent = true;
        _seconds = 0;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _check({bool silent = false}) async {
    if (_checking) return;
    _checking = true;
    try {
      final o = await ShopApi.status(widget.order.id, widget.order.token, check: !silent);
      if (o.paid || o.step > 0) {
        _poll?.cancel();
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => TrackScreen(order: o)));
        return;
      }
      if (!mounted) return;
      if (_sent && (o.mpesaState == 'cancelled' || o.mpesaState == 'failed' || o.mpesaState == 'timeout')) {
        setState(() {
          _sent = false;
          _error = o.mpesaState == 'cancelled'
              ? 'The payment was cancelled on your phone. Tap "Resend prompt" to try again.'
              : 'The M-Pesa prompt expired or failed. Tap "Resend prompt" to try again.';
        });
        return;
      }
      if (!silent) toast(context, 'Payment not received yet. Enter your PIN on the M-Pesa prompt.');
    } catch (e) {
      if (!silent && mounted) toast(context, '$e');
    } finally {
      _checking = false;
    }
  }

  Future<void> _changeNumber() async {
    final c = TextEditingController(text: _phone);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('M-Pesa number'),
        content: TextField(controller: c, keyboardType: TextInputType.phone, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Send prompt')),
        ],
      ),
    );
    if (v != null && v.replaceAll(RegExp(r'[^0-9]'), '').length >= 9) {
      setState(() => _phone = v);
      _send();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mm = (_seconds ~/ 60).toString();
    final ss = (_seconds % 60).toString().padLeft(2, '0');
    final amount = money(widget.order.amountTotal);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(children: [
            Row(children: [
              const BackSquare(),
              const SizedBox(width: 12),
              Expanded(child: Text('Payment', style: head(20))),
              Text(widget.order.name, style: const TextStyle(color: C.muted)),
            ]),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              decoration: cardBox(),
              child: Column(children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: const BoxDecoration(color: C.greenLight, shape: BoxShape.circle),
                  child: const Icon(Icons.phone_iphone_rounded, color: C.green, size: 46),
                ),
                const SizedBox(height: 14),
                Text(_error != null ? 'Prompt not sent' : 'Check your phone', style: head(21)),
                const SizedBox(height: 8),
                Text(
                  _error ??
                      (_sending
                          ? 'Sending the M-Pesa prompt to $_phone…'
                          : 'We sent an M-Pesa prompt to $_phone. Enter your PIN to pay $amount.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, height: 1.5, color: _error != null ? const Color(0xFFB91C1C) : C.muted),
                ),
                const SizedBox(height: 14),
                if (_sent && _error == null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(color: C.greenLight, borderRadius: BorderRadius.circular(999)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 2, color: C.accent)),
                      const SizedBox(width: 8),
                      Text('Waiting for payment · $mm:$ss', style: const TextStyle(color: C.green, fontSize: 13.5)),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: cardBox(),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _step('1', 'Open the M-Pesa prompt on your phone'),
                _step('2', 'Check the amount is $amount'),
                _step('3', 'Enter your PIN. This page moves on by itself.'),
              ]),
            ),
            const Spacer(),
            PrimaryButton("I've paid · check now", onTap: () => _check()),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _outline('Resend prompt', _sending ? null : _send)),
              const SizedBox(width: 10),
              Expanded(child: _outline('Change number', _sending ? null : _changeNumber)),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _step(String n, String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 20, child: Text(n, style: head(14, color: C.green))),
          Expanded(child: Text(t, style: const TextStyle(fontSize: 14))),
        ]),
      );

  Widget _outline(String label, VoidCallback? onTap) => SizedBox(
        height: 48,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: C.green,
            backgroundColor: Colors.white,
            side: const BorderSide(color: C.line),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(label),
        ),
      );
}
