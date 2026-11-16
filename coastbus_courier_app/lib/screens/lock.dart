import 'package:flutter/material.dart';
import '../fmt.dart';
import '../master.dart';
import '../session.dart';
import '../sync.dart';
import '../ui.dart';
import 'home.dart';

const roleLabels = {'clerk': 'Office clerk', 'loader': 'Loader / driver', 'supervisor': 'Supervisor'};

class LockScreen extends StatelessWidget {
  const LockScreen({super.key});

  Future<void> _signIn(BuildContext context, Map<String, dynamic> st) async {
    if (s(st['pin_hash']).isEmpty) {
      toast(context, 'No PIN set for ${st['name']}. Set it in Odoo (Courier → Staff & PINs).', bad: true);
      return;
    }
    if (await askPinOf(context, st, 'Sign in')) Session.i.forceSignIn(st);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Sync.i,
      builder: (context, _) {
        final m = Master.i;
        final users = Session.i.users();
        return Scaffold(
          appBar: AppBar(
            title: Text(m.loaded ? '${m.company['name'] ?? 'Courier'} · ${m.hubName}' : 'Coast Bus Courier'),
            actions: const [SyncChip()],
          ),
          body: !m.loaded
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.cloud_download_outlined, size: 56, color: C.muted),
                    const SizedBox(height: 12),
                    Text('Downloading branches, tariffs and staff…', style: h(17)),
                    const SizedBox(height: 6),
                    Text(Sync.i.error.isEmpty ? 'Needs the internet once.' : Sync.i.error, textAlign: TextAlign.center, style: const TextStyle(color: C.muted)),
                    const SizedBox(height: 16),
                    FilledButton.icon(onPressed: () => Sync.i.run(full: true), icon: const Icon(Icons.refresh), label: const Text('Try again')),
                  ]),
                )
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Text('Who is working?', style: h(22)),
                  const SizedBox(height: 4),
                  const Text('Tap your name and enter your PIN.', style: TextStyle(color: C.muted)),
                  const SizedBox(height: 14),
                  if (users.isEmpty) const Empty(Icons.people_outline, 'No staff for this branch yet. Add them in Odoo: Courier → Configuration → Staff & PINs.'),
                  GridView.count(
                    crossAxisCount: MediaQuery.of(context).size.width > 520 ? 3 : 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.45,
                    children: [
                      for (final u in users)
                        InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _signIn(context, u),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: box(),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                              CircleAvatar(
                                backgroundColor: u['role'] == 'supervisor' ? C.amber : C.ink,
                                child: Text(s(u['name']).isEmpty ? '?' : s(u['name'])[0], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                              ),
                              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(s(u['name']), maxLines: 1, overflow: TextOverflow.ellipsis, style: h(15)),
                                Text(roleLabels[u['role']] ?? s(u['role']), style: const TextStyle(color: C.muted, fontSize: 12.5)),
                              ]),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ]),
        );
      },
    );
  }
}
