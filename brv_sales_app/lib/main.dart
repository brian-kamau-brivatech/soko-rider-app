import 'package:flutter/material.dart';
import 'backup.dart';
import 'bus.dart';
import 'config.dart';
import 'db.dart';
import 'dev/dev_app.dart';
import 'licence.dart';
import 'sales.dart';
import 'screens/activation_screen.dart';
import 'screens/lock_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/shell.dart';
import 'session.dart';
import 'settings.dart';
import 'sync.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDevApp) {
    runApp(const DevApp());
    return;
  }
  await Licence.i.load();
  await Db.get();
  await Settings.i.load();
  runApp(const BrvPos());
}

final navKey = GlobalKey<NavigatorState>();

class BrvPos extends StatefulWidget {
  const BrvPos({super.key});
  @override
  State<BrvPos> createState() => _BrvPosState();
}

class _BrvPosState extends State<BrvPos> with WidgetsBindingObserver {
  bool _wasIn = false;
  bool _syncing = false;
  bool? _hasUsers;
  bool _seededHere = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Session.i.addListener(_onSession);
    dataVersion.addListener(_checkUsers);
    Licence.i.addListener(_onLicence);
    _onLicence();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Licence.i.linked) Sync.i.run();
  }

  /// Once the licence is active: seed a brand-new company (manager), start syncing, check for users.
  Future<void> _onLicence() async {
    final lic = Licence.i;
    if (!lic.usable) return;
    if (!_syncing) {
      _syncing = true;
      if (isManagerApp && !lic.seeded) await Db.seedCompany();
      Sync.i.start();
      if (isManagerApp) Backup.auto();
    }
    await _checkUsers();
  }

  Future<void> _checkUsers() async {
    final has = await Session.anyUsers();
    final here = await Db.kv('seeded_here') == '1';
    if (mounted && (has != _hasUsers || here != _seededHere)) {
      setState(() {
        _hasUsers = has;
        _seededHere = here;
      });
    }
  }

  /// When the app locks (button or no touch), close every open screen and empty the cart.
  void _onSession() {
    final inNow = Session.i.signedIn;
    if (_wasIn && !inNow) {
      Cart.i.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => navKey.currentState?.popUntil((r) => r.isFirst));
    }
    _wasIn = inNow;
  }

  Widget _home() {
    final lic = Licence.i;
    if (!lic.linked || lic.status == 'none' || lic.status == 'waiting') return const ActivationScreen();
    if (!lic.usable) return const BlockedScreen();
    if (_hasUsers == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_hasUsers == false) {
      // a brand-new company: the manager sets up the business; everyone else waits for that data
      if (isManagerApp && _seededHere) return SetupScreen(onDone: _checkUsers);
      return const WaitingDataScreen();
    }
    if (!Session.i.signedIn) return const LockScreen();
    Session.i.lockMinutes = Settings.i.lockMinutes;
    return const Shell();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => Session.i.touch(),
      child: MaterialApp(
        title: appTitle,
        navigatorKey: navKey,
        debugShowCheckedModeBanner: false,
        theme: appTheme(),
        home: ListenableBuilder(
          listenable: Listenable.merge([Session.i, Settings.i, Licence.i]),
          builder: (context, _) => _home(),
        ),
      ),
    );
  }
}
