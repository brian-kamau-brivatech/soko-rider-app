import 'package:flutter/material.dart';
import 'screens/login_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SokoRiderApp());
}

class SokoRiderApp extends StatelessWidget {
  const SokoRiderApp({super.key});

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
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
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
        fontFamily: 'Roboto',
      ),
      home: const LoginScreen(),
    );
  }
}
