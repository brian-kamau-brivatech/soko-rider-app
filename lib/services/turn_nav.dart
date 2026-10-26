import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Free road routing (OpenStreetMap / OSRM), the same router Soko uses for
/// delivery prices.
const String kOsrmBase = 'https://router.project-osrm.org';

/// One manoeuvre of the route ("turn left onto Kenyatta Ave").
class NavStep {
  final String type; // turn, depart, arrive, roundabout, fork, ...
  final String modifier; // left, right, slight left, straight, uturn, ...
  final String name; // road name after the manoeuvre ('' if unnamed)
  final int exit; // roundabout exit number (0 if none)
  final LatLng point; // where the manoeuvre happens
  int pathIndex = 0; // index of [point] on the route line

  NavStep(this.type, this.modifier, this.name, this.exit, this.point);

  bool get isArrive => type == 'arrive';

  /// Short instruction for the banner, e.g. "Turn left onto Moi Road".
  String get text {
    final onto = name.isEmpty ? '' : ' onto $name';
    switch (type) {
      case 'depart':
        return name.isEmpty ? 'Start riding' : 'Start on $name';
      case 'arrive':
        return 'Arrive at the drop-off';
      case 'roundabout':
      case 'rotary':
      case 'roundabout turn':
        return exit > 0 ? 'At the roundabout, take the ${_ordinal(exit)} exit$onto' : 'Go through the roundabout$onto';
      case 'exit roundabout':
      case 'exit rotary':
        return 'Exit the roundabout$onto';
      case 'fork':
        return '${_keep()}$onto';
      case 'merge':
        return 'Merge ${_side()}$onto';
      case 'on ramp':
        return 'Take the ramp ${_side()}$onto';
      case 'off ramp':
        return 'Take the exit ${_side()}$onto';
      case 'end of road':
        return '${_turn()} at the end of the road$onto';
      case 'continue':
      case 'new name':
        if (modifier == 'straight' || modifier.isEmpty) return 'Continue straight$onto';
        return '${_turn()}$onto';
      default:
        return '${_turn()}$onto';
    }
  }

  String _side() => modifier.contains('left') ? 'on the left' : (modifier.contains('right') ? 'on the right' : '');
  String _keep() => modifier.contains('left') ? 'Keep left' : (modifier.contains('right') ? 'Keep right' : 'Keep straight');
  String _turn() {
    switch (modifier) {
      case 'left':
        return 'Turn left';
      case 'right':
        return 'Turn right';
      case 'slight left':
        return 'Keep slightly left';
      case 'slight right':
        return 'Keep slightly right';
      case 'sharp left':
        return 'Turn sharp left';
      case 'sharp right':
        return 'Turn sharp right';
      case 'uturn':
        return 'Make a U-turn';
      default:
        return 'Continue straight';
    }
  }

  /// What the voice says right at the turn ("Turn left now").
  String get spokenNow {
    if (isArrive) return 'You have arrived';
    final t = text;
    final cut = t.indexOf(' onto ');
    return '${cut > 0 ? t.substring(0, cut) : t} now';
  }

  IconData get icon {
    if (type == 'arrive') return Icons.flag_rounded;
    if (type.contains('roundabout') || type.contains('rotary')) {
      return modifier.contains('left') ? Icons.roundabout_left : Icons.roundabout_right;
    }
    if (type == 'fork' || type == 'merge' || type.contains('ramp')) {
      return modifier.contains('left') ? Icons.fork_left : (modifier.contains('right') ? Icons.fork_right : Icons.straight);
    }
    switch (modifier) {
      case 'left':
        return Icons.turn_left;
      case 'right':
        return Icons.turn_right;
      case 'slight left':
        return Icons.turn_slight_left;
      case 'slight right':
        return Icons.turn_slight_right;
      case 'sharp left':
        return Icons.turn_sharp_left;
      case 'sharp right':
        return Icons.turn_sharp_right;
      case 'uturn':
        return Icons.u_turn_left;
      default:
        return Icons.straight;
    }
  }

  static String _ordinal(int n) {
    if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
    switch (n % 10) {
      case 1:
        return '${n}st';
      case 2:
        return '${n}nd';
      case 3:
        return '${n}rd';
      default:
        return '${n}th';
    }
  }
}

/// A road route from OSRM: the line to draw and the manoeuvres.
class NavRoute {
  final List<LatLng> path;
  final List<double> cum; // metres along the route at each path point
  final List<NavStep> steps;
  final double distanceM;
  final double durationS;

  NavRoute(this.path, this.cum, this.steps, this.distanceM, this.durationS);

  static Future<NavRoute> fetch(LatLng from, LatLng to, {String base = kOsrmBase}) async {
    final url = '$base/route/v1/driving/'
        '${from.longitude.toStringAsFixed(6)},${from.latitude.toStringAsFixed(6)};'
        '${to.longitude.toStringAsFixed(6)},${to.latitude.toStringAsFixed(6)}'
        '?overview=full&geometries=geojson&steps=true';
    final res = await http
        .get(Uri.parse(url), headers: {'User-Agent': 'SokoRider/1.0'})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('Route service error ${res.statusCode}');
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final routes = data['routes'] as List? ?? const [];
    if (data['code'] != 'Ok' || routes.isEmpty) throw Exception('No road route found');
    final r = routes.first as Map<String, dynamic>;
    final coords = ((r['geometry'] as Map)['coordinates'] as List)
        .map((c) => LatLng(((c as List)[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();
    if (coords.length < 2) throw Exception('Route too short');
    const d = Distance();
    final cum = <double>[0];
    for (var i = 1; i < coords.length; i++) {
      cum.add(cum[i - 1] + d.as(LengthUnit.Meter, coords[i - 1], coords[i]));
    }
    final steps = <NavStep>[];
    for (final leg in (r['legs'] as List? ?? const [])) {
      for (final s in ((leg as Map)['steps'] as List? ?? const [])) {
        final m = (s as Map)['maneuver'] as Map;
        final loc = m['location'] as List;
        steps.add(NavStep(
          '${m['type'] ?? ''}',
          '${m['modifier'] ?? ''}',
          '${s['name'] ?? ''}'.trim().isNotEmpty ? '${s['name']}'.trim() : '${s['ref'] ?? ''}'.trim(),
          (m['exit'] as num?)?.toInt() ?? 0,
          LatLng((loc[1] as num).toDouble(), (loc[0] as num).toDouble()),
        ));
      }
    }
    // Place each manoeuvre on the line, in order.
    var from0 = 0;
    for (final st in steps) {
      var best = from0;
      var bestD = double.infinity;
      for (var i = from0; i < coords.length; i++) {
        final dd = d.as(LengthUnit.Meter, coords[i], st.point);
        if (dd < bestD) {
          bestD = dd;
          best = i;
        }
        if (bestD < 1) break;
      }
      st.pathIndex = best;
      from0 = best;
    }
    return NavRoute(coords, cum, steps, (r['distance'] as num).toDouble(), (r['duration'] as num).toDouble());
  }
}

/// Where the rider is on the route right now.
class NavProgress {
  final NavStep? next; // the next manoeuvre
  final NavStep? after; // the one after it (shown as "Then")
  final double toNextM; // metres to the next manoeuvre
  final double remainingM; // metres to the destination
  final double remainingS; // seconds to the destination
  final bool arrived;
  const NavProgress(this.next, this.after, this.toNextM, this.remainingM, this.remainingS, this.arrived);
}

/// Follows the rider along the route: next turn, distance, voice, re-routing.
class TurnNavigator {
  final LatLng destination;
  final void Function() onChanged;
  final FlutterTts _tts = FlutterTts();

  NavRoute? route;
  NavProgress? progress;
  bool muted = false;
  bool loading = false;
  String? error;

  int _stepIdx = 1;
  int _seg = 0;
  int _offCount = 0;
  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);
  final Set<String> _spoken = {};
  bool _disposed = false;

  TurnNavigator({required this.destination, required this.onChanged}) {
    _initVoice();
  }

  Future<void> _initVoice() async {
    try {
      await _tts.setLanguage('en-GB');
    } catch (_) {}
    try {
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
    } catch (_) {}
  }

  Future<void> say(String text) async {
    if (muted || _disposed) return;
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  /// Gets a fresh route from [from]. Returns false if routing failed.
  Future<bool> load(LatLng from, {bool announce = true}) async {
    if (loading) return false;
    loading = true;
    error = null;
    onChanged();
    try {
      final r = await NavRoute.fetch(from, destination);
      if (_disposed) return false;
      route = r;
      _stepIdx = r.steps.length > 1 ? 1 : 0;
      _seg = 0;
      _offCount = 0;
      _spoken.clear();
      update(from, 0);
      if (announce && progress?.next != null) {
        final km = r.distanceM / 1000;
        say('${km >= 1 ? '${km.toStringAsFixed(1)} kilometres' : '${r.distanceM.round()} metres'} to go. '
            '${_distPhrase(progress!.toNextM)}${progress!.next!.text}');
        _spoken.add('far$_stepIdx');
      }
      return true;
    } catch (e) {
      error = 'Could not get the road route. Check internet.';
      return false;
    } finally {
      loading = false;
      if (!_disposed) onChanged();
    }
  }

  /// Call on every GPS fix.
  void update(LatLng pos, double accuracyM) {
    final r = route;
    if (r == null) return;
    const d = Distance();

    // Nearest point on the route line (search near the last match first).
    var bestSeg = _seg;
    var bestOff = double.infinity;
    var bestT = 0.0;
    final lo = math.max(0, _seg - 30);
    for (var i = lo; i < r.path.length - 1; i++) {
      final res = _project(pos, r.path[i], r.path[i + 1]);
      if (res.$1 < bestOff) {
        bestOff = res.$1;
        bestSeg = i;
        bestT = res.$2;
      }
      // Far beyond the match: stop searching.
      if (i > bestSeg + 200 && bestOff < 30) break;
    }
    _seg = bestSeg;
    final segLen = r.cum[bestSeg + 1] - r.cum[bestSeg];
    final along = r.cum[bestSeg] + segLen * bestT;

    // Off the route? Re-route (not more than every 12 s).
    if (bestOff > math.max(45, accuracyM * 1.5)) {
      _offCount++;
      if (_offCount >= 2 && DateTime.now().difference(_lastReroute).inSeconds > 12) {
        _lastReroute = DateTime.now();
        say('Rerouting');
        load(pos, announce: false).then((ok) {
          if (ok && progress?.next != null) {
            say('${_distPhrase(progress!.toNextM)}${progress!.next!.text}');
          }
        });
        return;
      }
    } else {
      _offCount = 0;
    }

    // Skip manoeuvres already passed.
    while (_stepIdx < r.steps.length - 1 && r.cum[r.steps[_stepIdx].pathIndex] - along < 12) {
      _stepIdx++;
    }
    final next = r.steps.isEmpty ? null : r.steps[_stepIdx];
    final after = _stepIdx + 1 < r.steps.length ? r.steps[_stepIdx + 1] : null;
    final toNext = next == null ? 0.0 : math.max(0.0, r.cum[next.pathIndex] - along);
    final remaining = math.max(0.0, r.cum.last - along);
    final straightToDest = d.as(LengthUnit.Meter, pos, destination);
    final arrived = remaining < 25 || straightToDest < 25;
    final remainingS = r.distanceM > 0 ? r.durationS * remaining / r.distanceM : 0.0;
    progress = NavProgress(next, after, toNext, remaining, remainingS, arrived);

    // Voice: early warning, then "in 100 metres", then "now".
    if (next != null) {
      final k = '$_stepIdx';
      if (arrived) {
        if (_spoken.add('arrived')) say('You have arrived at the drop-off');
      } else if (toNext <= 35) {
        if (_spoken.add('now$k')) say(next.spokenNow);
      } else if (toNext <= 130) {
        if (_spoken.add('near$k')) {
          _spoken.add('far$k');
          say('${_distPhrase(toNext)}${next.text}');
        }
      } else if (toNext <= 450) {
        if (_spoken.add('far$k')) say('${_distPhrase(toNext)}${next.text}');
      }
    }
    onChanged();
  }

  static String _distPhrase(double m) {
    if (m <= 35) return '';
    if (m < 1000) {
      final r = m < 200 ? (m / 10).round() * 10 : (m / 50).round() * 50;
      return 'In $r metres, ';
    }
    return 'In ${(m / 1000).toStringAsFixed(1)} kilometres, ';
  }

  /// (distance in metres from p to segment a-b, position 0..1 along it)
  static (double, double) _project(LatLng p, LatLng a, LatLng b) {
    const mPerDegLat = 111320.0;
    final mPerDegLng = 111320.0 * math.cos(p.latitude * math.pi / 180);
    final ax = (a.longitude - p.longitude) * mPerDegLng, ay = (a.latitude - p.latitude) * mPerDegLat;
    final bx = (b.longitude - p.longitude) * mPerDegLng, by = (b.latitude - p.latitude) * mPerDegLat;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : -(ax * dx + ay * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    return (math.sqrt(cx * cx + cy * cy), t);
  }

  void dispose() {
    _disposed = true;
    try {
      _tts.stop();
    } catch (_) {}
  }
}

/// "80 m", "1.2 km"
String navDistance(double m) {
  if (m < 1000) {
    final r = m < 100 ? (m / 10).round() * 10 : (m / 50).round() * 50;
    return '${math.max(r, 0)} m';
  }
  return '${(m / 1000).toStringAsFixed(1)} km';
}

/// "12 min", "1 h 5 min"
String navDuration(double s) {
  final min = (s / 60).ceil();
  if (min < 60) return '$min min';
  return '${min ~/ 60} h ${min % 60} min';
}
