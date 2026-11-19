/// Which app this build is: manager | sales | etr | dev (set by --dart-define=APP_MODE when building).
const appMode = String.fromEnvironment('APP_MODE', defaultValue: 'manager');
bool get isManagerApp => appMode == 'manager';
bool get isSalesApp => appMode == 'sales';
bool get isDevApp => appMode == 'dev';

/// BRV Handheld ETR: one handheld that sells and manages (like Manager + Sales) and signs every sale with KRA eTIMS.
bool get isEtrApp => appMode == 'etr';

/// Apps that own the company data: seed a new company, run backups, set up the business, take BRV commands.
bool get isOwnerApp => isManagerApp || isEtrApp;

/// BRV Cloud address (built into the app, never shown or changed on the device).
const defaultServer = String.fromEnvironment('BRV_SERVER', defaultValue: 'http://pos.brvsystems.co.ke');

String get appTitle => isDevApp
    ? 'BRV Licence'
    : isEtrApp
        ? 'BRV Handheld ETR'
        : (isManagerApp ? 'BRV Pos Manager' : 'BRV Pos Sales');
