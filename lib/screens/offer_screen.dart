import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config.dart';
import '../services/alert_service.dart';
import '../services/odoo_service.dart';
import '../services/presence_service.dart';
import '../widgets/common.dart';

/// Full-screen "New delivery request": rings until the rider answers or time runs out.
/// Pops `true` if the rider accepted.
class OfferScreen extends StatefulWidget {
  final DispatchOffer offer;
  final PresenceService presence;
  const OfferScreen({super.key, required this.offer, required this.presence});

  @override
  State<OfferScreen> createState() => _OfferScreenState();
}

class _OfferScreenState extends State<OfferScreen> {
  late int _left;
  Timer? _tick;
  bool _sending = false;
  bool _ringing = false;

  DispatchOffer get offer => widget.offer;

  @override
  void initState() {
    super.initState();
    _left = offer.expiresAt.difference(DateTime.now()).inSeconds;
    // Already ringing: Home started the alert when the request arrived.
    _ringing = true;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = offer.expiresAt.difference(DateTime.now()).inSeconds;
      if (!mounted) return;
      setState(() => _left = left);
      if (left <= 0) {
        _stopRing();
        _tick?.cancel();
        Navigator.of(context).pop(false);
      }
    });
  }

  void _startRing() {
    AlertService.startForOffer(offer);
    _ringing = true;
  }

  void _stopRing() {
    if (!_ringing) return;
    AlertService.stop();
    _ringing = false;
  }

  @override
  void dispose() {
    _tick?.cancel();
    _stopRing();
    super.dispose();
  }

  Future<void> _answer(bool accept) async {
    _stopRing();
    String? reason;
    if (!accept) {
      reason = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Why are you declining?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ),
            for (final r in ['Too far', 'Already busy', 'Bike problem', 'Taking a break', 'Other'])
              ListTile(title: Text(r), onTap: () => Navigator.pop(ctx, r)),
          ]),
        ),
      );
      if (reason == null) {
        if (_left > 0) _startRing();
        return; // closed the sheet: still deciding
      }
    }
    setState(() => _sending = true);
    final err = await widget.presence.respond(offer, accept, reason: reason);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      Navigator.of(context).pop(false);
      return;
    }
    Navigator.of(context).pop(accept);
  }

  @override
  Widget build(BuildContext context) {
    final o = offer.order;
    final total = offer.secondsLeft <= 0 ? 60 : offer.secondsLeft;
    final progress = (_left / total).clamp(0.0, 1.0);

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: SokoColors.sheet,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('NEW DELIVERY REQUEST',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF7BD66A), fontWeight: FontWeight.w800, letterSpacing: 1.5, fontSize: 13)),
                const SizedBox(height: 24),
                Center(
                  child: SizedBox(
                    width: 150,
                    height: 150,
                    child: Stack(fit: StackFit.expand, children: [
                      CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 10,
                        backgroundColor: SokoColors.sheetLine,
                        color: _left <= 10 ? Colors.orange : SokoColors.green,
                      ),
                      Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Text('${_left < 0 ? 0 : _left}',
                              style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.w800)),
                          const Text('seconds', style: TextStyle(color: Color(0xFF9CA3AF))),
                        ]),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 28),
                Text(o.deliveryArea.isEmpty ? 'Delivery in Nakuru' : o.deliveryArea,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
                if (o.trackingNo.isNotEmpty)
                  Text(o.trackingNo, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 14)),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: const Color(0xFF262A30), borderRadius: BorderRadius.circular(20)),
                  child: Column(children: [
                    _row('Pick up at', AppConfig.shopName),
                    _row('You are', offer.riderDistanceKm == null ? '—' : '${offer.riderDistanceKm!.toStringAsFixed(1)} km from the shop'),
                    if (o.distanceKm != null && o.distanceKm! > 0) _row('Trip', '${o.distanceKm!.toStringAsFixed(1)} km'),
                    _row('Payout', o.riderPayout != null && o.riderPayout! > 0 ? formatKsh(o.riderPayout) : 'Not set', green: true),
                  ]),
                ),
                const Spacer(),
                SizedBox(
                  height: 64,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: SokoColors.green,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    ),
                    onPressed: _sending ? null : () => _answer(true),
                    child: _sending
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                        : const Text('ACCEPT', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1)),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFF4B5563)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    onPressed: _sending ? null : () => _answer(false),
                    child: const Text('Decline', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value, {bool green = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Text(label, style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 14)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(value,
                textAlign: TextAlign.end,
                style: TextStyle(color: green ? const Color(0xFF7BD66A) : Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
          ),
        ]),
      );
}
