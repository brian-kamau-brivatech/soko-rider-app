class AppConfig {
  /// Odoo server (same one the website, rider app and customer app use).
  static const String baseUrl = 'https://odoo.sokoexpressmtaani.co.ke';
  /// How often the shop device checks for new orders.
  static const Duration pollEvery = Duration(seconds: 10);
}
