import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/login.dart';
import 'screens/shell.dart';
import 'store.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.i.init();
  if (Store.i.signedIn) Store.i.start();
  runApp(const SokoShopStaffApp());
}

class SokoShopStaffApp extends StatelessWidget {
  const SokoShopStaffApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(useMaterial3: true);
    return MaterialApp(
      title: 'Soko Shop',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: C.bg,
        colorScheme: ColorScheme.fromSeed(seedColor: C.green, primary: C.green, secondary: C.navy),
        textTheme: GoogleFonts.plusJakartaSansTextTheme(base.textTheme).apply(bodyColor: C.ink, displayColor: C.ink),
      ),
      home: ListenableBuilder(
        listenable: Store.i,
        builder: (context, _) => Store.i.signedIn ? const Shell() : const LoginScreen(),
      ),
    );
  }
}
