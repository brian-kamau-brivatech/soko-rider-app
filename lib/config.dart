class AppConfig {
  // Live Production Endpoints
  static const String odooBaseUrl = 'https://odoo.sokoexpressmtaani.co.ke';
  static const String wsStreamUrl = 'wss://odoo.sokoexpressmtaani.co.ke/ws';
  static const String odooDbName  = 'soko';

  // Soko Express Mtaani Shop (Nakuru CBD Pick-up Point)
  static const String shopName = 'Soko Shop, Nakuru CBD';
  static const double shopLatitude  = -0.303099;
  static const double shopLongitude = 36.080026;

  // Background GPS Settings
  static const int gpsIntervalSeconds       = 3;
  static const int gpsDistanceFilterMeters  = 5;
  static const int shopGeofenceRadiusMeters = 100;
}
