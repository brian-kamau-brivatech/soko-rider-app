import 'package:flutter/material.dart';
import 'backup.dart';
import 'db.dart';
import 'sales.dart';
import 'screens/lock_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/shell.dart';
import 'session.dart';
import 'settings.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Db.get();
  await Settings.i.load();
  final hasUsers = await Session.anyUsers();
  if (hasUsers) Backup.auto();
  runApp(BrvPosSales(setUp: hasUsers));
}

class BrvPosSales extends StatefulWidget {
  final bool setUp;
  const BrvPosSales({super.key, required this.setUp});
  @override
  State<BrvPosSales> createState() => _BrvPosSalesState();
}

final navKey = GlobalKey<NavigatorState>();

class _BrvPosSalesState extends State<BrvPosSales> {
  late bool _setUp = widget.setUp;
  bool _wasIn = false;

  @override
  void initState() {
    super.initState();
    Session.i.addListener(_onSession);
  }

  /// When the app locks (button or no touch), close every open screen and empty the cart,
  /// so the next person starts clean and nothing stays visible.
  void _onSession() {
    final inNow = Session.i.signedIn;
    if (_wasIn && !inNow) {
      Cart.i.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => navKey.currentState?.popUntil((r) => r.isFirst));
    }
    _wasIn = inNow;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => Session.i.touch(),
      child: MaterialApp(
        title: 'BRV Pos Sales',
        navigatorKey: navKey,
        debugShowCheckedModeBanner: false,
        theme: appTheme(),
        home: ListenableBuilder(
          listenable: Listenable.merge([Session.i, Settings.i]),
          builder: (context, _) {
            if (!_setUp) return SetupScreen(onDone: () => setState(() => _setUp = true));
            if (!Session.i.signedIn) return const LockScreen();
            Session.i.lockMinutes = Settings.i.lockMinutes;
            return const Shell();
          },
        ),
      ),
    );
  }
}
