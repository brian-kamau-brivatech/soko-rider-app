import 'dart:async';
import 'dart:io' show Platform;
import 'package:geolocator/geolocator.dart';
import '../config.dart';

/// The single GPS stream for the whole app.
///
/// Several features need location at once (being Online for dispatch, and
/// streaming a live delivery). Each one "holds" the hub; GPS runs while anyone
/// holds it and stops when the last one lets go. On Android it runs as a
/// foreground service with a notification, so it keeps working with the
/// screen off.
class LocationHub {
  LocationHub._();
  static final LocationHub instance = LocationHub._();

  final _controller = StreamController<Position>.broadcast();
  StreamSubscription<Position>? _sub;
  final Set<String> _holders = {};
  bool _preciseActive = false;
  Position? last;

  Stream<Position> get positions => _controller.stream;
  bool get isRunning => _sub != null;

  /// [precise] = live delivery (every few metres). Otherwise a lighter
  /// "online" mode that is enough for distance-from-shop.
  Future<void> hold(String who, {bool precise = false}) async {
    _holders.add(precise ? '$who:precise' : who);
    await _restartIfNeeded();
  }

  Future<void> release(String who) async {
    _holders.removeWhere((h) => h == who || h == '$who:precise');
    await _restartIfNeeded();
  }

  bool get _wantPrecise => _holders.any((h) => h.endsWith(':precise'));

  Future<void> _restartIfNeeded() async {
    if (_holders.isEmpty) {
      await _sub?.cancel();
      _sub = null;
      return;
    }
    if (_sub != null && _preciseActive == _wantPrecise) return;
    await _sub?.cancel();
    _preciseActive = _wantPrecise;
    _sub = Geolocator.getPositionStream(locationSettings: _settings(_preciseActive)).listen(
      (p) {
        last = p;
        _controller.add(p);
      },
      onError: (Object e) => _controller.addError(e),
    );
  }

  LocationSettings _settings(bool precise) {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: precise ? LocationAccuracy.high : LocationAccuracy.medium,
        distanceFilter: precise ? AppConfig.gpsDistanceFilterMeters : 50,
        intervalDuration: Duration(seconds: precise ? AppConfig.gpsIntervalSeconds : 30),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: precise ? 'Soko delivery in progress' : 'You are online for Soko',
          notificationText: precise
              ? 'Your location is being shared with the customer.'
              : 'Soko dispatch can send you delivery requests.',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    return LocationSettings(
      accuracy: precise ? LocationAccuracy.high : LocationAccuracy.medium,
      distanceFilter: precise ? AppConfig.gpsDistanceFilterMeters : 50,
    );
  }
}
