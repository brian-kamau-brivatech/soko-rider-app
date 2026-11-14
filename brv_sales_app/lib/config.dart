/// Which app this build is: manager | sales | dev (set by --dart-define=APP_MODE when building).
const appMode = String.fromEnvironment('APP_MODE', defaultValue: 'manager');
bool get isManagerApp => appMode == 'manager';
bool get isSalesApp => appMode == 'sales';
bool get isDevApp => appMode == 'dev';

/// BRV Cloud address (can be changed in the hidden settings: tap the logo 5 times).
const defaultServer = String.fromEnvironment('BRV_SERVER', defaultValue: 'http://pos.brvsystems.co.ke');

String get appTitle => isDevApp ? 'BRV Licence' : (isManagerApp ? 'BRV Pos Manager' : 'BRV Pos Sales');
