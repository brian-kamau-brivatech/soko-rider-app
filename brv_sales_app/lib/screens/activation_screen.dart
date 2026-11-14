import 'dart:async';
import 'package:flutter/material.dart';
import '../config.dart';
import '../licence.dart';
import '../sync.dart';
import '../ui.dart';

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) => Image.asset('assets/brv_logo.png', height: 110);
}

class _CodeCard extends StatelessWidget {
  const _CodeCard();
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
        decoration: box(color: C.ink, border: false),
        child: Column(children: [
          const Text('This device code', style: TextStyle(color: Color(0xFFCBD5E1), fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          FittedBox(child: SelectableText(Licence.i.shownCode, style: h(32, color: Colors.white).copyWith(letterSpacing: 2))),
        ]),
      );
}

/// Shown until this device is added to a company.
class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key});
  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    Licence.i.hello();
    _t = Timer.periodic(const Duration(seconds: 6), (_) => Licence.i.hello());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lic = Licence.i;
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(22, 30, 22, 24), children: [
          const Center(child: _Logo()),
          const SizedBox(height: 8),
          Center(child: Text(appTitle, style: h(25))),
          const SizedBox(height: 20),
          const _CodeCard(),
          const SizedBox(height: 18),
          Text(
            isManagerApp
                ? 'Send this code to BRV Integrated Systems. When your licence is activated this screen opens the app by itself.'
                : 'Ask your manager to add this code in BRV Pos Manager > More > Devices. Then this screen opens the app by itself.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15.5, height: 1.4),
          ),
          const SizedBox(height: 18),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Flexible(child: Text(lic.message.isEmpty ? 'Waiting for activation...' : lic.message, style: muted, textAlign: TextAlign.center)),
          ]),
          const SizedBox(height: 26),
          OutlinedButton.icon(onPressed: () => lic.hello(), icon: const Icon(Icons.refresh), label: const Text('Check now')),
          const SizedBox(height: 20),
          const Center(child: Text('Needs internet once to activate. After that the app works offline.', style: muted, textAlign: TextAlign.center)),
        ]),
      ),
    );
  }
}

/// Licence ended, suspended, device removed, or phone clock wound back.
class BlockedScreen extends StatefulWidget {
  const BlockedScreen({super.key});
  @override
  State<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends State<BlockedScreen> {
  bool _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    await Licence.i.hello();
    if (Licence.i.usable) await Sync.i.run();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final lic = Licence.i;
    final (title, body) = switch (lic.status) {
      'revoked' => ('Device removed', 'This device was removed from ${lic.company}. Ask your manager to add it again.'),
      'suspended' => ('Licence suspended', 'The licence of ${lic.company} is suspended. Contact BRV Integrated Systems.'),
      _ when lic.clockTampered => ('Check the date', 'The phone\'s date was set back. Connect to the internet and tap Check again.'),
      _ => ('Licence expired', 'The licence of ${lic.company} has ended. Contact BRV Integrated Systems to renew; your data is safe.'),
    };
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(22, 40, 22, 24), children: [
          const Center(child: _Logo()),
          const SizedBox(height: 16),
          const Icon(Icons.lock_clock, size: 54, color: C.red),
          const SizedBox(height: 10),
          Center(child: Text(title, style: h(24))),
          const SizedBox(height: 10),
          Text(body, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15.5, height: 1.4)),
          const SizedBox(height: 22),
          const _CodeCard(),
          const SizedBox(height: 22),
          FilledButton(onPressed: _busy ? null : _retry, child: Text(_busy ? 'Checking...' : 'Check again')),
          if (lic.message.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(lic.message, style: muted, textAlign: TextAlign.center)),
          const SizedBox(height: 18),
          const Center(child: Text('BRV Integrated Systems', style: muted)),
        ]),
      ),
    );
  }
}

/// A new device of an existing company: wait for the data to arrive.
class WaitingDataScreen extends StatefulWidget {
  const WaitingDataScreen({super.key});
  @override
  State<WaitingDataScreen> createState() => _WaitingDataScreenState();
}

class _WaitingDataScreenState extends State<WaitingDataScreen> {
  @override
  void initState() {
    super.initState();
    Sync.i.run();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListenableBuilder(
            listenable: Sync.i,
            builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(22, 60, 22, 24), children: [
              const Center(child: _Logo()),
              const SizedBox(height: 20),
              Center(child: Text(Licence.i.company, style: h(24), textAlign: TextAlign.center)),
              const SizedBox(height: 14),
              if (Sync.i.busy) const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 14),
              Text(
                Sync.i.busy
                    ? 'Getting your company\'s products, users and settings...'
                    : (Sync.i.error.isNotEmpty
                        ? Sync.i.error
                        : (isManagerApp
                            ? 'Nothing from your company yet. If this is a new phone for the manager, the old manager phone must sync first.'
                            : 'Nothing from your company yet. The manager must set up the business in BRV Pos Manager first (and be online).')),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15.5, height: 1.4),
              ),
              const SizedBox(height: 22),
              FilledButton(onPressed: Sync.i.busy ? null : () => Sync.i.run(), child: const Text('Try again')),
            ]),
          ),
        ),
      );
}
