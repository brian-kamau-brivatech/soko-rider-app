class AppConfig {
  /// 'pos' = Utange POS (handheld at the bar), 'manager' = Utange Manager (phone).
  static const String mode = String.fromEnvironment('APP_MODE', defaultValue: 'pos');
  static bool get isManager => mode == 'manager';

  /// Prefilled on the setup screen (can be changed there).
  static const String defaultServer = String.fromEnvironment('ODOO_URL', defaultValue: '');
  static const String defaultDb = String.fromEnvironment('ODOO_DB', defaultValue: 'utangevillage');

  static String get appName => isManager ? 'Utange Manager' : 'Utange POS';
}
