import 'package:flutter/material.dart';
import 'db.dart';
import 'screens/home.dart';
import 'screens/login_screen.dart';
import 'screens/settings_screen.dart';
import 'session.dart';
import 'settings.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.i.load();
  await Db.get();
  await Session.ensureAdmin();
  await Session.i.restore();
  runApp(const BrvPosApp());
}

class BrvPosApp extends StatelessWidget {
  const BrvPosApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: C.brand, primary: C.brand, secondary: C.gold, tertiary: C.gold);
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    return MaterialApp(
      title: 'BRV POS',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: C.bg,
        appBarTheme: const AppBarTheme(
          backgroundColor: C.brand,
          foregroundColor: Colors.white,
          surfaceTintColor: C.brand,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.2),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: C.brand,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: C.brand,
            side: const BorderSide(color: C.brand2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: C.gold, foregroundColor: Colors.white),
        chipTheme: base.chipTheme.copyWith(selectedColor: C.goldLight),
        progressIndicatorTheme: const ProgressIndicatorThemeData(color: C.gold),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null),
          trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.brand : null),
        ),
      ),
      home: ListenableBuilder(
        listenable: Listenable.merge([Settings.i, Session.i]),
        builder: (context, _) {
          if (!Session.i.signedIn) return const LoginScreen();
          if (!Settings.i.ready) return Session.i.admin ? const SettingsScreen(firstRun: true) : const NotReadyScreen();
          return const Home();
        },
      ),
    );
  }
}
