import 'dart:async';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:web_socket_channel/io.dart';
import '../config.dart';

class LocationStreamService {
  IOWebSocketChannel? _channel;
  StreamSubscription<Position>? _positionStream;
  bool isStreaming = false;

  /// Start streaming GPS updates for a specific order token
  Future<bool> startStreaming({
    required String wsUrl,
    required String trackingToken,
    required Function(Position pos) onLocationUpdate,
  }) async {
    // 1. Check & Request Device GPS Permission (100% Free hardware)
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return false;
    }

    try {
      // 2. Connect to lightweight real-time WebSocket bridge
      final uri = Uri.parse('$wsUrl?role=rider&token=$trackingToken');
      _channel = IOWebSocketChannel.connect(uri);

      // 3. Configure battery-friendly GPS stream
      const locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: AppConfig.gpsDistanceFilterMeters, // e.g. 5 meters
      );

      _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings)
          .listen((Position position) {
        onLocationUpdate(position);

        if (_channel != null) {
          final payload = jsonEncode({
            'lat': position.latitude,
            'lng': position.longitude,
            'heading': position.heading,
            'speed': position.speed,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
          _channel!.sink.add(payload);
        }
      });

      isStreaming = true;
      return true;
    } catch (e) {
      print('WebSocket GPS stream error: $e');
      stopStreaming();
      return false;
    }
  }

  /// Stop streaming when delivery is completed or paused
  void stopStreaming() {
    _positionStream?.cancel();
    _channel?.sink.close();
    _positionStream = null;
    _channel = null;
    isStreaming = false;
  }
}
