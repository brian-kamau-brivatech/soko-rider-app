import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'ui.dart';

/// Hardware imager (broadcast), keyboard-wedge scanners, typing, or the camera.
class Scanner {
  static const _ev = EventChannel('brv/scan');
  static const _beep = MethodChannel('brv/beep');
  static Stream<String>? _stream;

  static Stream<String> get stream => _stream ??= _ev.receiveBroadcastStream().map((e) => '$e').asBroadcastStream();

  static Future<void> good() async {
    try {
      await _beep.invokeMethod('good');
    } catch (_) {
      SystemSound.play(SystemSoundType.click);
    }
  }

  static Future<void> bad() async {
    try {
      await _beep.invokeMethod('bad');
    } catch (_) {
      HapticFeedback.heavyImpact();
    }
  }
}

/// Scan field used on every scanning screen. Hardware scans arrive without touching anything.
class ScanBar extends StatefulWidget {
  final void Function(String code) onCode;
  final String hint;
  const ScanBar({super.key, required this.onCode, this.hint = 'Scan or type the waybill number'});
  @override
  State<ScanBar> createState() => _ScanBarState();
}

class _ScanBarState extends State<ScanBar> {
  final _c = TextEditingController();
  final _f = FocusNode();
  StreamSubscription<String>? _sub;
  bool _typing = false;
  String _last = '';
  DateTime _lastAt = DateTime(2000);

  @override
  void initState() {
    super.initState();
    try {
      _sub = Scanner.stream.listen(_got, onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  void _got(String raw) {
    final code = raw.trim();
    if (code.isEmpty) return;
    // the same label read twice in a row by the imager (or wedge + broadcast) counts once
    if (code == _last && DateTime.now().difference(_lastAt).inMilliseconds < 1200) return;
    _last = code;
    _lastAt = DateTime.now();
    widget.onCode(code);
  }

  Future<void> _camera() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const CameraScan()));
    if (code != null) _got(code);
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: TextField(
          controller: _c,
          focusNode: _f,
          autofocus: true,
          // no soft keyboard unless "type" is chosen: keyboard-wedge scanners still type here
          keyboardType: _typing ? TextInputType.visiblePassword : TextInputType.none,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(hintText: widget.hint, prefixIcon: const Icon(Icons.qr_code_scanner)),
          onSubmitted: (v) {
            _c.clear();
            _got(v);
            _f.requestFocus();
          },
        ),
      ),
      const SizedBox(width: 6),
      IconButton.filledTonal(
        tooltip: 'Type',
        onPressed: () {
          setState(() => _typing = !_typing);
          _f.unfocus();
          Future.delayed(const Duration(milliseconds: 80), () => _f.requestFocus());
        },
        icon: Icon(_typing ? Icons.keyboard_hide : Icons.keyboard),
      ),
      IconButton.filled(tooltip: 'Camera', onPressed: _camera, icon: const Icon(Icons.photo_camera)),
    ]);
  }
}

class CameraScan extends StatefulWidget {
  const CameraScan({super.key});
  @override
  State<CameraScan> createState() => _CameraScanState();
}

class _CameraScanState extends State<CameraScan> {
  final _ctl = MobileScannerController(formats: const [BarcodeFormat.code128, BarcodeFormat.qrCode, BarcodeFormat.code39, BarcodeFormat.ean13]);
  bool _done = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Point at the label', style: TextStyle(color: Colors.white)),
        actions: [IconButton(onPressed: () => _ctl.toggleTorch(), icon: const Icon(Icons.flash_on))],
      ),
      body: Stack(children: [
        MobileScanner(
          controller: _ctl,
          onDetect: (cap) {
            if (_done) return;
            for (final b in cap.barcodes) {
              final v = b.rawValue;
              if (v != null && v.isNotEmpty) {
                _done = true;
                Navigator.of(context).pop(v);
                return;
              }
            }
          },
        ),
        Center(
          child: Container(
            width: 260,
            height: 180,
            decoration: BoxDecoration(border: Border.all(color: C.amber, width: 3), borderRadius: BorderRadius.circular(16)),
          ),
        ),
      ]),
    );
  }
}
