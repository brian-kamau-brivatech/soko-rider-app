import 'package:flutter/material.dart';
import 'printer.dart';
import 'screens/activation.dart';
import 'screens/home.dart';
import 'screens/lock.dart';
import 'session.dart';
import 'sync.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Sync.i.init();
  await Printer.load();
  Session.i.startIdleWatch();
  if (Sync.i.activated) Sync.i.start();
  runApp(const CourierApp());
}

class CourierApp extends StatelessWidget {
  const CourierApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Coast Bus Courier',
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      builder: (context, child) => Listener(onPointerDown: (_) => Session.i.touch(), child: child),
      home: const Gate(),
    );
  }
}

/// Not activated → activation. Switched off in Odoo → activation. Nobody signed in → lock screen.
class Gate extends StatelessWidget {
  const Gate({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Sync.i, Session.i]),
      builder: (context, _) {
        if (!Sync.i.activated) return const ActivationScreen();
        if (Sync.i.revoked) return const ActivationScreen(revoked: true);
        if (!Session.i.signedIn) return const LockScreen();
        return const HomeScreen();
      },
    );
  }
}
