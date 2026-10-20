import 'dart:async';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'location_hub.dart';

/// What the rider sees about their live tracking.
enum LiveStatus {
  idle,
  gpsOff,
  permissionDenied,
  connecting, // waiting for server connection or first GPS fix
  live, // GPS fix sent to server
  reconnecting, // server connection dropped; retrying, GPS still running
}

/// Streams the phone's real GPS to the Soko WebSocket bridge during a delivery.
///
/// GPS comes from [LocationHub] in precise mode (foreground service on
/// Android, keeps working with the screen off). If the connection drops it
/// reconnects and resends the latest position.
class LocationStreamService {
  static const _holder = 'delivery';

  WebSocketChannel? _channel;
  StreamSubscription<Position>? _positionSub;
  StreamSubscription? _wsSub;
  Timer? _reconnectTimer;

  String _wsUrl = '';
  String _token = '';
  bool _running = false;
  bool _wsConnected = false;
  Position? _lastPosition;

  void Function(LiveStatus status)? _onStatus;
  void Function(Position pos)? _onPosition;

  bool get isStreaming => _running;

  /// Checks GPS + permission and asks the rider if needed.
  /// Returns the blocking status, or null if everything is OK.
  static Future<LiveStatus?> ensurePermission({bool ask = true}) async {
    if (!await Geolocator.isLocationServiceEnabled()) return LiveStatus.gpsOff;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && ask) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever ||
        permission == LocationPermission.unableToDetermine) {
      return LiveStatus.permissionDenied;
    }
    return null;
  }

  Future<LiveStatus> startStreaming({
    required String wsUrl,
    required String trackingToken,
    required void Function(Position pos) onLocationUpdate,
    required void Function(LiveStatus status) onStatus,
  }) async {
    final blocked = await ensurePermission();
    if (blocked != null) {
      onStatus(blocked);
      return blocked;
    }

    _wsUrl = wsUrl;
    _token = trackingToken;
    _onPosition = onLocationUpdate;
    _onStatus = onStatus;
    _running = true;
    _emit(LiveStatus.connecting);

    unawaited(_connect());

    final hub = LocationHub.instance;
    _positionSub = hub.positions.listen(
      (Position position) {
        _lastPosition = position;
        _onPosition?.call(position);
        _send(position);
      },
      onError: (_) => _emit(LiveStatus.gpsOff),
    );
    await hub.hold(_holder, precise: true);
    // Show the last known fix straight away (e.g. rider was already Online).
    final last = hub.last;
    if (last != null && _running) {
      _lastPosition = last;
      _onPosition?.call(last);
    }
    return LiveStatus.connecting;
  }

  Future<void> _connect() async {
    if (!_running) return;
    try {
      final uri = Uri.parse('$_wsUrl?role=rider&token=${Uri.encodeQueryComponent(_token)}');
      final channel = WebSocketChannel.connect(uri);
      await channel.ready.timeout(const Duration(seconds: 15));
      if (!_running) {
        channel.sink.close();
        return;
      }
      _channel = channel;
      _wsConnected = true;
      _wsSub = channel.stream.listen(
        (_) {}, // server messages are not needed by the rider app
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
        cancelOnError: true,
      );
      if (_lastPosition != null) {
        _send(_lastPosition!);
      } else {
        _emit(LiveStatus.connecting);
      }
    } catch (_) {
      _onDisconnected();
    }
  }

  void _onDisconnected() {
    _wsConnected = false;
    _wsSub?.cancel();
    _wsSub = null;
    _channel = null;
    if (!_running) return;
    _emit(LiveStatus.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), _connect);
  }

  void _send(Position position) {
    if (!_wsConnected || _channel == null) {
      _emit(LiveStatus.reconnecting);
      return;
    }
    try {
      _channel!.sink.add(jsonEncode({
        'type': 'LOCATION_UPDATE',
        'tracking_no': _token,
        'lat': position.latitude,
        'lng': position.longitude,
        'accuracy': position.accuracy,
        'heading': position.heading,
        'speed': position.speed, // metres per second, as reported by the phone
        'timestamp': position.timestamp.millisecondsSinceEpoch,
      }));
      _emit(LiveStatus.live);
    } catch (_) {
      _onDisconnected();
    }
  }

  void _emit(LiveStatus s) => _onStatus?.call(s);

  /// Stop streaming when delivery is completed or the screen is closed.
  void stopStreaming() {
    _running = false;
    _reconnectTimer?.cancel();
    _positionSub?.cancel();
    _wsSub?.cancel();
    _channel?.sink.close();
    _positionSub = null;
    _wsSub = null;
    _channel = null;
    _wsConnected = false;
    _onStatus = null;
    _onPosition = null;
    LocationHub.instance.release(_holder);
  }
}
