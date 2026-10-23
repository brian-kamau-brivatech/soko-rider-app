import 'package:flutter/material.dart';
import 'db.dart';
import 'screens/home.dart';
import 'screens/settings_screen.dart';
import 'settings.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.i.load();
  await Db.get();
  runApp(const BrvPosApp());
}

class BrvPosApp extends StatelessWidget {
  const BrvPosApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(useMaterial3: true);
    return MaterialApp(
      title: 'BRV POS',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: C.bg,
        colorScheme: ColorScheme.fromSeed(seedColor: C.brand, primary: C.brand, secondary: C.green),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.white, surfaceTintColor: Colors.white, elevation: 0),
      ),
      home: ListenableBuilder(
        listenable: Settings.i,
        builder: (context, _) => Settings.i.ready ? const Home() : const SettingsScreen(firstRun: true),
      ),
    );
  }
}
