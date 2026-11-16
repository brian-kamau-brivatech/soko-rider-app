import 'package:flutter/material.dart';
import 'fmt.dart';
import 'session.dart';

/// Coast Bus colours: deep navy and amber.
class C {
  static const ink = Color(0xFF0F2A4A);
  static const ink2 = Color(0xFF1D4472);
  static const amber = Color(0xFFE8A317);
  static const amberLight = Color(0xFFFDF3DC);
  static const bg = Color(0xFFF3F5F9);
  static const line = Color(0xFFE2E6EE);
  static const text = Color(0xFF0F172A);
  static const muted = Color(0xFF64748B);
  static const green = Color(0xFF15803D);
  static const greenLight = Color(0xFFDCFCE7);
  static const red = Color(0xFFB91C1C);
  static const redLight = Color(0xFFFEE2E2);
  static const blueLight = Color(0xFFE0ECFB);
}

TextStyle h(double size, {FontWeight w = FontWeight.w800, Color color = C.text}) => TextStyle(fontSize: size, fontWeight: w, color: color, letterSpacing: -0.3);

BoxDecoration box({Color color = Colors.white, double r = 16, bool border = true}) =>
    BoxDecoration(color: color, borderRadius: BorderRadius.circular(r), border: border ? Border.all(color: C.line) : null);

ThemeData appTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: C.ink, primary: C.ink, secondary: C.amber, surface: Colors.white);
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: C.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: C.ink,
      foregroundColor: Colors.white,
      elevation: 0,
      titleTextStyle: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.ink,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 50),
        foregroundColor: C.ink,
        side: const BorderSide(color: C.line, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.ink, width: 1.6)),
    ),
  );
}

void toast(BuildContext context, String msg, {bool bad = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), backgroundColor: bad ? C.red : C.ink, behavior: SnackBarBehavior.floating));
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'OK', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: C.red, minimumSize: const Size(0, 44)) : FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}

Future<String?> ask(BuildContext context, String title, {String initial = '', String label = '', bool number = false, bool caps = false}) async {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        textCapitalization: caps ? TextCapitalization.characters : TextCapitalization.sentences,
        decoration: InputDecoration(labelText: label.isEmpty ? null : label),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(0, 44)), onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
      ],
    ),
  );
}

/// PIN of a given person (driver acknowledgement, supervisor approval). Returns true when correct.
Future<bool> askPinOf(BuildContext context, Map<String, dynamic> staff, String why) async {
  final ok = await showDialog<bool>(context: context, builder: (ctx) => _PinDialog(staff: staff, why: why));
  return ok == true;
}

/// Pick a supervisor and check their PIN. Returns the supervisor or null.
Future<Map<String, dynamic>?> askSupervisor(BuildContext context, String why) async {
  if (Session.i.isSupervisor) return Session.i.staff;
  final sups = Session.i.supervisors();
  if (sups.isEmpty) {
    toast(context, 'No supervisor set up in Odoo.', bad: true);
    return null;
  }
  final st = sups.length == 1
      ? sups.first
      : await showModalBottomSheet<Map<String, dynamic>>(
          context: context,
          builder: (ctx) => SafeArea(
            child: ListView(shrinkWrap: true, children: [
              ListTile(title: Text('Supervisor approval', style: h(17)), subtitle: Text(why)),
              for (final x in sups) ListTile(leading: const Icon(Icons.verified_user_outlined), title: Text(s(x['name'])), onTap: () => Navigator.pop(ctx, x)),
            ]),
          ),
        );
  if (st == null || !context.mounted) return null;
  return await askPinOf(context, st, why) ? st : null;
}

class _PinDialog extends StatefulWidget {
  final Map<String, dynamic> staff;
  final String why;
  const _PinDialog({required this.staff, required this.why});
  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  String _pin = '';
  String _err = '';

  void _tap(String k) {
    setState(() {
      _err = '';
      if (k == '<') {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
      } else if (_pin.length < 6) {
        _pin += k;
      }
    });
  }

  void _ok() {
    if (checkPin(widget.staff, _pin)) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _err = 'Wrong PIN';
        _pin = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(s(widget.staff['name'])),
      content: SizedBox(
        width: 300,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.why, style: const TextStyle(color: C.muted)),
          const SizedBox(height: 12),
          Text(_pin.isEmpty ? 'Enter PIN' : '•' * _pin.length, style: h(26, color: _pin.isEmpty ? C.muted : C.text)),
          if (_err.isNotEmpty) Text(_err, style: const TextStyle(color: C.red, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          PinPad(onKey: _tap, onOk: _pin.length >= 4 ? _ok : null),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel'))],
    );
  }
}

class PinPad extends StatelessWidget {
  final void Function(String) onKey;
  final VoidCallback? onOk;
  const PinPad({super.key, required this.onKey, this.onOk});

  @override
  Widget build(BuildContext context) {
    Widget key(String k, {Widget? child, VoidCallback? tap}) => Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            width: 72,
            height: 56,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(72, 56), backgroundColor: Colors.white),
              onPressed: tap ?? () => onKey(k),
              child: child ?? Text(k, style: h(22)),
            ),
          ),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']]) Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final k in row) key(k)]),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        key('<', child: const Icon(Icons.backspace_outlined)),
        key('0'),
        Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(width: 72, height: 56, child: FilledButton(style: FilledButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(72, 56)), onPressed: onOk, child: const Icon(Icons.check))),
        ),
      ]),
    ]);
  }
}

class Empty extends StatelessWidget {
  final IconData icon;
  final String text;
  const Empty(this.icon, this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(28),
        child: Column(children: [Icon(icon, size: 48, color: C.muted), const SizedBox(height: 10), Text(text, textAlign: TextAlign.center, style: const TextStyle(color: C.muted))]),
      );
}

class Label extends StatelessWidget {
  final String text;
  const Label(this.text, {super.key});
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(2, 16, 2, 8), child: Text(text.toUpperCase(), style: const TextStyle(color: C.muted, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8)));
}

const stateLabels = {
  'booked': 'Booked',
  'loaded': 'Loaded',
  'in_transit': 'In transit',
  'at_hub': 'At transfer branch',
  'arrived': 'Ready for collection',
  'collected': 'Collected',
  'lost': 'Missing',
  'cancelled': 'Cancelled',
};

class StateChip extends StatelessWidget {
  final String state;
  const StateChip(this.state, {super.key});
  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (state) {
      'arrived' || 'collected' => (C.greenLight, C.green),
      'lost' || 'cancelled' => (C.redLight, C.red),
      'in_transit' || 'loaded' || 'at_hub' => (C.amberLight, const Color(0xFF8A5A00)),
      _ => (C.blueLight, C.ink),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(stateLabels[state] ?? state, style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 12.5)),
    );
  }
}
