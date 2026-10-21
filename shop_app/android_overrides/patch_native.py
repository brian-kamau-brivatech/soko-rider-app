"""Native Android setup for the Soko Shop app (run from shop_app/ after flutter create).

Reuses the rider app's ringing code (../android_overrides/MainActivity.kt) and adds:
  - keepAlive: a small foreground service so new orders still ring when the
    screen is locked (the shop device stays on the charger);
  - keepScreenOn: keep the display awake while the app is open.
"""
import glob, os, re

PKG = 'ke.co.sokoexpressmtaani.soko_staff'
main = glob.glob('android/app/src/main/kotlin/**/MainActivity.kt', recursive=True)[0]
src_dir = os.path.dirname(main)

s = open('../android_overrides/MainActivity.kt').read()
s = re.sub(r'^package .*$', 'package ' + PKG, s, count=1, flags=re.M)
s = s.replace('"Delivery request alert"', '"New order alert"')
s = s.replace('"Full-screen alert when Soko sends you a delivery request"', '"Rings when a new paid order comes in"')
s = s.replace('"Delivery requests"', '"Shop orders"')
s = s.replace('"Rings when Soko sends you a delivery request"', '"Shop order notifications"')
extra = '''                    "keepAlive" -> {
                        val on = call.argument<Boolean>("on") ?: true
                        val svc = Intent(ctx, KeepAliveService::class.java)
                        if (on) {
                            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(svc) else ctx.startService(svc)
                        } else {
                            ctx.stopService(svc)
                        }
                        result.success(true)
                    }
                    "keepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        runOnUiThread {
                            if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()'''
assert '                    else -> result.notImplemented()' in s
s = s.replace('                    else -> result.notImplemented()', extra, 1)
open(main, 'w').write(s)

open(os.path.join(src_dir, 'KeepAliveService.kt'), 'w').write('''package %s

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** Keeps the shop app running (and polling for orders) while the screen is locked. */
class KeepAliveService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && nm != null && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Receiving orders", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while Soko Shop is listening for new orders"
                    setShowBadge(false)
                }
            )
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val n = builder
            .setContentTitle("Soko Shop is receiving orders")
            .setContentText("New paid orders will ring this device.")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, n)
        }
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "soko:shop").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        const val CHANNEL = "soko_shop_keepalive"
        const val NOTIF_ID = 4401
    }
}
''' % PKG)

p = 'android/app/src/main/AndroidManifest.xml'
c = open(p).read()
perms = ['INTERNET', 'POST_NOTIFICATIONS', 'WAKE_LOCK', 'VIBRATE', 'USE_FULL_SCREEN_INTENT',
         'FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_SPECIAL_USE']
tags = ''.join('    <uses-permission android:name="android.permission.%s" />\n' % x
               for x in perms if ('permission.%s"' % x) not in c)
c = c.replace('<application', tags + '    <application', 1)
svc = ('        <service android:name=".KeepAliveService" android:exported="false"'
       ' android:foregroundServiceType="specialUse">\n'
       '            <property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"'
       ' android:value="Shop counter device that must ring for new customer orders" />\n'
       '        </service>\n')
c = c.replace('</application>', svc + '    </application>', 1)
intents = '        <intent><action android:name="android.intent.action.DIAL" /><data android:scheme="tel" /></intent>\n'
if '<queries>' in c:
    c = c.replace('<queries>', '<queries>\n' + intents, 1)
else:
    c = c.replace('</manifest>', '    <queries>\n' + intents + '    </queries>\n</manifest>', 1)
c = c.replace('android:label="soko_staff"', 'android:label="Soko Shop"')
open(p, 'w').write(c)

os.makedirs('android/app/src/main/res/raw', exist_ok=True)
for src, dst in [('../assets/sound/soko_request.wav', 'android/app/src/main/res/raw/soko_request.wav'),
                 ('../android_overrides/keep.xml', 'android/app/src/main/res/raw/keep.xml')]:
    open(dst, 'wb').write(open(src, 'rb').read())
print('native setup done:', main)
print(c)
