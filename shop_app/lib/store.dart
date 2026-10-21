import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'alerts.dart';
import 'api.dart';
import 'config.dart';

/// Something the shop must see right now (shown full screen + ringing).
class ShopAlert {
  final ShopOrder order;
  final String kind; // 'new' | 'no_rider'
  ShopAlert(this.order, this.kind);
}

/// Shop device state: PIN, live board, alert settings, and the alert logic.
class Store extends ChangeNotifier {
  Store._();
  static final Store i = Store._();

  late SharedPreferences _p;
  String pin = '';
  String shopName = 'Soko Shop';
  Board? board;
  String? error;
  DateTime? updatedAt;
  Timer? _timer;
  bool _loading = false;

  // Alert settings
  String sound = 'ringtone';
  String vibration = 'heartbeat';
  bool keepRinging = true;
  bool ringNewOrder = true;
  bool ringNoRider = true;
  bool chimeRiderAtShop = true;
  bool chimePaid = true;
  bool screenOn = true;

  /// Alerts waiting to be shown (the UI listens and opens the alert screen).
  final ValueNotifier<ShopAlert?> alert = ValueNotifier<ShopAlert?>(null);

  // Events already announced, so each one rings once.
  final Set<String> _seen = {};
  bool _primed = false;

  bool get signedIn => pin.isNotEmpty;

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    pin = _p.getString('pin') ?? '';
    shopName = _p.getString('shop') ?? 'Soko Shop';
    sound = _p.getString('sound') ?? 'ringtone';
    vibration = _p.getString('vibration') ?? 'heartbeat';
    keepRinging = _p.getBool('keepRinging') ?? true;
    ringNewOrder = _p.getBool('ringNewOrder') ?? true;
    ringNoRider = _p.getBool('ringNoRider') ?? true;
    chimeRiderAtShop = _p.getBool('chimeRiderAtShop') ?? true;
    chimePaid = _p.getBool('chimePaid') ?? true;
    screenOn = _p.getBool('screenOn') ?? true;
    try {
      _seen.addAll((jsonDecode(_p.getString('seen') ?? '[]') as List).map((e) => '$e'));
      _primed = _seen.isNotEmpty;
    } catch (_) {}
  }

  Future<void> signIn(String newPin) async {
    shopName = await StaffApi.login(newPin);
    pin = newPin;
    await _p.setString('pin', pin);
    await _p.setString('shop', shopName);
    notifyListeners();
    start();
  }

  Future<void> signOut() async {
    stop();
    pin = '';
    board = null;
    await _p.remove('pin');
    await Alerts.keepAlive(false);
    notifyListeners();
  }

  void start() {
    if (!signedIn) return;
    Alerts.requestNotifications();
    Alerts.keepAlive(true);
    Alerts.keepScreenOn(screenOn);
    _timer?.cancel();
    _timer = Timer.periodic(AppConfig.pollEvery, (_) => refresh());
    refresh();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() async {
    if (!signedIn || _loading) return;
    _loading = true;
    try {
      final b = await StaffApi.board(pin);
      board = b;
      error = null;
      updatedAt = DateTime.now();
      _check(b);
    } on ApiError catch (e) {
      error = e.message;
      if (e.auth) await signOut();
    } catch (e) {
      error = '$e';
    }
    _loading = false;
    notifyListeners();
  }

  /// Decide what to ring for. The first load after sign-in only remembers
  /// what is already there (no ringing for old orders).
  void _check(Board b) {
    ShopAlert? ringFor;
    var chime = false;
    for (final o in b.orders) {
      final events = <String, String>{
        if (o.isNew && o.paid) 'new:${o.id}': 'new',
        if (o.isNew && o.paid) 'paid:${o.id}': 'paid',
        if (o.noRider) 'norider:${o.id}': 'no_rider',
        if (o.riderAtShop && !o.isDone) 'atshop:${o.id}:${o.rider}': 'at_shop',
      };
      events.forEach((key, kind) {
        if (_seen.contains(key)) return;
        _seen.add(key);
        if (!_primed) return;
        if (kind == 'new' && ringNewOrder) ringFor ??= ShopAlert(o, 'new');
        if (kind == 'no_rider' && ringNoRider) ringFor ??= ShopAlert(o, 'no_rider');
        if (kind == 'at_shop' && chimeRiderAtShop) chime = true;
        if (kind == 'paid' && chimePaid && !ringNewOrder) chime = true;
      });
    }
    _primed = true;
    if (_seen.length > 600) {
      final keep = _seen.toList().sublist(_seen.length - 400);
      _seen
        ..clear()
        ..addAll(keep);
    }
    _p.setString('seen', jsonEncode(_seen.toList()));

    final a = ringFor;
    if (a != null) {
      final o = a.order;
      Alerts.ring(
        title: a.kind == 'new' ? 'New order · ${o.trackingNo}' : 'No rider found · ${o.trackingNo}',
        body: a.kind == 'new'
            ? 'KSh ${o.amount.toStringAsFixed(0)} · ${o.count} items · ${o.address}'
            : 'Every free rider declined. Tap to assign one.',
        sound: sound,
        vibration: vibration,
        seconds: keepRinging ? 300 : 30,
      );
      alert.value = a;
    } else if (chime) {
      Alerts.chime(vibration);
    }
  }

  Future<void> silence() async {
    await Alerts.stop();
    alert.value = null;
    await Alerts.keepScreenOn(screenOn);
  }

  Future<void> setSetting(String key, Object value) async {
    switch (key) {
      case 'sound':
        sound = value as String;
        await _p.setString(key, sound);
      case 'vibration':
        vibration = value as String;
        await _p.setString(key, vibration);
      case 'keepRinging':
        keepRinging = value as bool;
      case 'ringNewOrder':
        ringNewOrder = value as bool;
      case 'ringNoRider':
        ringNoRider = value as bool;
      case 'chimeRiderAtShop':
        chimeRiderAtShop = value as bool;
      case 'chimePaid':
        chimePaid = value as bool;
      case 'screenOn':
        screenOn = value as bool;
        await Alerts.keepScreenOn(screenOn);
    }
    if (value is bool) await _p.setBool(key, value);
    notifyListeners();
  }
}
