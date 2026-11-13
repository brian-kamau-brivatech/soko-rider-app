import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'config.dart';
import 'idle.dart';
import 'mgr/mgr_login.dart';
import 'mgr/mgr_shell.dart';
import 'pos/cashier_screen.dart';
import 'pos/setup_screen.dart';
import 'pos/shell.dart';
import 'store.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.i.init();
  runApp(const UtangeApp());
}

class UtangeApp extends StatelessWidget {
  const UtangeApp({super.key});
  @override
  Widget build(BuildContext context) {
    final base = ThemeData(useMaterial3: true);
    return MaterialApp(
      navigatorKey: IdleLock.navigatorKey,
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => IdleLock.touch(),
        child: child ?? const SizedBox.shrink(),
      ),
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: C.bg,
        colorScheme: ColorScheme.fromSeed(seedColor: C.green, primary: C.green, secondary: C.navy),
        textTheme: GoogleFonts.plusJakartaSansTextTheme(base.textTheme).apply(bodyColor: C.ink, displayColor: C.ink),
      ),
      home: ListenableBuilder(
        listenable: Store.i,
        builder: (context, _) {
          final s = Store.i;
          if (AppConfig.isManager) return s.managerReady ? const MgrShell() : const MgrLogin();
          if (!s.posReady) return const SetupScreen();
          if (s.needsCashier) return const CashierScreen();
          IdleLock.touch();
          return const PosShell();
        },
      ),
    );
  }
}
