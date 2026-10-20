import 'package:flutter/material.dart';
import '../services/alert_service.dart';
import 'common.dart';

/// Profile section: choose how a delivery request rings and vibrates, test it,
/// and fix the phone settings that stop it ringing when the screen is locked.
class AlertSettingsCard extends StatefulWidget {
  const AlertSettingsCard({super.key});

  @override
  State<AlertSettingsCard> createState() => _AlertSettingsCardState();
}

class _AlertSettingsCardState extends State<AlertSettingsCard> with WidgetsBindingObserver {
  String _vibration = 'call';
  String _sound = 'ringtone';
  Map<String, bool> _status = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from phone Settings: refresh the checklist.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final v = await AlertService.vibration();
    final s = await AlertService.sound();
    final st = await AlertService.status();
    if (!mounted) return;
    setState(() {
      _vibration = v;
      _sound = s;
      _status = st;
    });
  }

  Future<void> _pick(String title, Map<String, String> options, String current, ValueChanged<String> onPick) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
          for (final e in options.entries)
            ListTile(
              leading: Icon(e.key == current ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: e.key == current ? SokoColors.green : SokoColors.slate),
              title: Text(e.value),
              trailing: IconButton(
                tooltip: 'Try it',
                icon: const Icon(Icons.play_circle_outline, color: SokoColors.green),
                onPressed: () => AlertService.preview(
                  vibration: options == AlertService.vibrations ? e.key : _vibration,
                  sound: options == AlertService.sounds ? e.key : 'none',
                ),
              ),
              onTap: () => Navigator.pop(ctx, e.key),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (chosen != null) onPick(chosen);
  }

  Widget _choice(IconData icon, String label, String value, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(children: [
            Icon(icon, color: SokoColors.green, size: 22),
            const SizedBox(width: 12),
            Text(label, style: const TextStyle(color: SokoColors.slate, fontSize: 14)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(value,
                  textAlign: TextAlign.end,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: SokoColors.ink, fontWeight: FontWeight.w700, fontSize: 14)),
            ),
            const Icon(Icons.chevron_right, color: SokoColors.slate),
          ]),
        ),
      );

  Widget _check(String label, bool? ok, String fix, VoidCallback onFix) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(ok == false ? Icons.error_outline : Icons.check_circle,
              color: ok == false ? SokoColors.red : SokoColors.green, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13.5, color: SokoColors.ink))),
          if (ok == false)
            TextButton(onPressed: onFix, child: Text(fix, style: const TextStyle(fontWeight: FontWeight.w800))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return SokoCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Request alert', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: SokoColors.ink)),
        const SizedBox(height: 2),
        const Text('Rings and vibrates when you are Online, even with the screen locked.',
            style: TextStyle(fontSize: 12.5, color: SokoColors.slate)),
        _choice(Icons.vibration, 'Vibration', AlertService.vibrations[_vibration] ?? _vibration, () {
          _pick('Choose vibration', AlertService.vibrations, _vibration, (k) async {
            await AlertService.setVibration(k);
            setState(() => _vibration = k);
          });
        }),
        const Divider(height: 1),
        _choice(Icons.music_note_outlined, 'Sound', AlertService.sounds[_sound] ?? _sound, () {
          _pick('Choose sound', AlertService.sounds, _sound, (k) async {
            await AlertService.setSound(k);
            setState(() => _sound = k);
          });
        }),
        const Divider(height: 1),
        const SizedBox(height: 6),
        _check('Notifications allowed', _status['notifications'], 'Allow', () async {
          await AlertService.requestNotifications();
          await Future<void>.delayed(const Duration(seconds: 2));
          if ((await AlertService.status())['notifications'] == false) await AlertService.openAppSettings();
          _load();
        }),
        _check('Show over lock screen', _status['fullScreen'], 'Allow', AlertService.openFullScreenSettings),
        _check('Keep running when locked (battery)', _status['battery'], 'Allow', AlertService.openBatterySettings),
        const SizedBox(height: 6),
        SizedBox(
          height: 48,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Text('Test alert (lock your screen within 5 s)', style: TextStyle(fontWeight: FontWeight.w700)),
            onPressed: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Lock your screen now. The test alert rings in 5 seconds for 15 seconds.')));
              await Future<void>.delayed(const Duration(seconds: 5));
              await AlertService.start(title: 'Test delivery request', body: 'This is how a Soko request rings', seconds: 15);
              await Future<void>.delayed(const Duration(seconds: 15));
              await AlertService.stop();
            },
          ),
        ),
        const SizedBox(height: 6),
      ]),
    );
  }
}
