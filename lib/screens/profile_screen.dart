import 'package:flutter/material.dart';
import '../services/presence_service.dart';
import '../services/push_service.dart';
import '../services/rider_data.dart';
import '../widgets/common.dart';
import 'login_screen.dart';

class ProfileScreen extends StatelessWidget {
  final RiderData data;
  final PresenceService presence;
  const ProfileScreen({super.key, required this.data, required this.presence});

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You will need your phone number and PIN to log in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Log out')),
        ],
      ),
    );
    if (ok != true) return;
    if (presence.online) await presence.goOffline();
    await data.service.logout();
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([data, presence]),
      builder: (context, _) {
        final p = data.profile;
        final vehicle = [p?.vehicleType ?? '', p?.vehicleRegNo ?? ''].where((s) => s.isNotEmpty).map((s) => s.toUpperCase()).join(' · ');
        return SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 120),
            children: [
              const Text('Profile', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: SokoColors.ink)),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: SokoColors.sheet, borderRadius: BorderRadius.circular(24)),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundColor: SokoColors.green,
                      child: Text(initials(p?.name ?? ''), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p?.name ?? '…', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                          Text(vehicle.isEmpty ? 'Soko Courier' : 'Soko Courier · $vehicle',
                              style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SokoCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(children: [
                  _row(Icons.phone_android, 'Login phone', p?.phone ?? '—'),
                  const Divider(height: 1),
                  _row(Icons.two_wheeler, 'Vehicle', vehicle.isEmpty ? 'Not set in Soko' : vehicle),
                  const Divider(height: 1),
                  _row(Icons.cloud_done_outlined, 'Soko server',
                      data.active == null ? 'Checking…' : (data.active!.ok ? 'Connected' : (data.active!.error ?? 'Error'))),
                  const Divider(height: 1),
                  _row(Icons.gps_fixed, 'GPS', data.gpsProblem == null ? 'Ready' : 'Needs attention'),
                  const Divider(height: 1),
                  _row(Icons.wifi_tethering, 'Dispatch', presence.online ? 'Online' : 'Offline'),
                  const Divider(height: 1),
                  _row(Icons.notifications_active_outlined, 'Request alerts', PushService.instance.status ?? '—'),
                ]),
              ),
              const SizedBox(height: 22),
              SizedBox(
                height: 54,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.logout, color: SokoColors.red),
                  label: const Text('Log out', style: TextStyle(color: SokoColors.red, fontWeight: FontWeight.w700)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: SokoColors.redLight, width: 2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                  onPressed: () => _logout(context),
                ),
              ),
              const SizedBox(height: 12),
              const Center(child: Text('Forgot PIN? Ask Soko admin to reset it.', style: TextStyle(color: SokoColors.slate, fontSize: 12))),
            ],
          ),
        );
      },
    );
  }

  Widget _row(IconData icon, String label, String value) => Padding(
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
        ]),
      );
}
