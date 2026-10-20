import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'services/odoo_service.dart';
import 'services/push_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Stay logged in: riders open straight to their home dashboard.
  // Push alerts for delivery requests (skipped if this build has no Firebase keys).
  await PushService.instance.init();
  final service = OdooService();
  final profile = await service.getSavedProfile();
  runApp(SokoRiderApp(startHome: profile != null, service: service));
}

class SokoRiderApp extends StatelessWidget {
  final bool startHome;
  final OdooService service;
  const SokoRiderApp({super.key, required this.startHome, required this.service});

  // Official Soko Express Mtaani Brand Colors
  static const Color sokoNavy = Color(0xFF0C2340);
  static const Color sokoNavyDark = Color(0xFF071629);
  static const Color sokoGreen = Color(0xFF43A027);
  static const Color sokoGreenLight = Color(0xFFEDF7E8);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soko Express Rider',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF4F5F7),
        colorScheme: ColorScheme.fromSeed(
          seedColor: sokoGreen,
          primary: sokoNavy,
          secondary: sokoGreen,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: sokoNavy,
          elevation: 0.5,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: sokoNavy,
            fontSize: 17,
            fontWeight: FontWeight.bold,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: sokoGreen,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        // Same typeface as the Soko tracking page
        textTheme: GoogleFonts.plusJakartaSansTextTheme(),
      ),
      home: startHome ? HomeShell(odooService: service) : const LoginScreen(),
    );
  }
}
