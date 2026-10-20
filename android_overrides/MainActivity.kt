package ke.co.sokoexpressmtaani.rider_app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createRequestChannel()
        SokoAlert.createAlertChannel(this)
        applyAlertIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        applyAlertIntent(intent)
    }

    /** Opened from a delivery-request alert: show the app on top of the lock screen. */
    private fun applyAlertIntent(i: Intent?) {
        if (i != null && i.getBooleanExtra(SokoAlert.EXTRA_ALERT, false)) showOverLockScreen(true)
    }

    private fun showOverLockScreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "soko/alert").setMethodCallHandler { call, result ->
            val ctx = applicationContext
            try {
                when (call.method) {
                    "start" -> {
                        SokoAlert.start(
                            ctx,
                            call.argument<String>("title") ?: "New delivery request",
                            call.argument<String>("body") ?: "Open Soko Rider to accept",
                            call.argument<String>("vibration") ?: "call",
                            call.argument<String>("sound") ?: "ringtone",
                            call.argument<Int>("seconds") ?: 60
                        )
                        result.success(true)
                    }
                    "stop" -> {
                        SokoAlert.stop(ctx)
                        runOnUiThread { showOverLockScreen(false) }
                        result.success(true)
                    }
                    "preview" -> {
                        SokoAlert.preview(
                            ctx,
                            call.argument<String>("vibration") ?: "call",
                            call.argument<String>("sound") ?: "ringtone"
                        )
                        result.success(true)
                    }
                    "status" -> result.success(SokoAlert.status(ctx))
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7701)
                        }
                        result.success(true)
                    }
                    "openFullScreenSettings" -> {
                        val i = if (Build.VERSION.SDK_INT >= 34)
                            Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName"))
                        else appSettingsIntent()
                        safeStart(i)
                        result.success(true)
                    }
                    "openBatterySettings" -> {
                        val ok = Build.VERSION.SDK_INT >= 23 &&
                            safeStart(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
                        if (!ok) safeStart(appSettingsIntent())
                        result.success(true)
                    }
                    "openAppSettings" -> {
                        safeStart(appSettingsIntent())
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("alert_error", e.message, null)
            }
        }
    }

    private fun appSettingsIntent() = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))

    private fun safeStart(i: Intent): Boolean = try {
        startActivity(i)
        true
    } catch (e: Exception) {
        false
    }

    /**
     * "Delivery requests" channel with the Soko chime, used by Firebase push
     * alerts when the app is fully closed.
     */
    private fun createRequestChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val sound = Uri.parse("android.resource://$packageName/raw/soko_request")
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val channel = NotificationChannel(CHANNEL_ID, "Delivery requests", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Rings when Soko sends you a delivery request"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 600, 300, 600, 300, 900)
            enableLights(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setSound(sound, attributes)
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val CHANNEL_ID = "soko_requests"
    }
}

/**
 * Rings the phone for a delivery request, also when the screen is locked:
 * wakes the screen, shows a full-screen alert, loops the chosen sound on the
 * alarm volume and repeats the chosen vibration until stopped.
 */
object SokoAlert {
    const val CHANNEL_ID = "soko_alert"
    const val EXTRA_ALERT = "soko_alert"
    private const val NOTIF_ID = 4711

    private val handler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val stopRunnable = Runnable { stopSoundAndVibration() }
    private var appContext: Context? = null

    val PATTERNS: Map<String, LongArray> = mapOf(
        "call" to longArrayOf(0, 1000, 800),
        "heartbeat" to longArrayOf(0, 150, 120, 300, 900),
        "rapid" to longArrayOf(0, 200, 150),
        "long" to longArrayOf(0, 2500, 600),
        "sos" to longArrayOf(0, 150, 100, 150, 100, 150, 300, 450, 100, 450, 100, 450, 300, 150, 100, 150, 100, 150, 1200),
        "wave" to longArrayOf(0, 100, 80, 200, 80, 400, 80, 800, 600)
    )

    fun createAlertChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        // Silent channel: the app plays the chosen sound and vibration itself.
        val ch = NotificationChannel(CHANNEL_ID, "Delivery request alert", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Full-screen alert when Soko sends you a delivery request"
            setSound(null, null)
            enableVibration(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        nm.createNotificationChannel(ch)
    }

    fun start(ctx: Context, title: String, body: String, vibration: String, sound: String, seconds: Int) {
        appContext = ctx
        stopSoundAndVibration()
        createAlertChannel(ctx)
        wakeScreen(ctx)
        showNotification(ctx, title, body)
        startSound(ctx, sound, true)
        startVibration(ctx, vibration, true)
        handler.postDelayed(stopRunnable, (seconds.coerceIn(5, 300) * 1000).toLong())
    }

    fun stop(ctx: Context) {
        appContext = ctx
        stopSoundAndVibration()
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        nm?.cancel(NOTIF_ID)
    }

    /** Short sample on the Profile screen. */
    fun preview(ctx: Context, vibration: String, sound: String) {
        appContext = ctx
        stopSoundAndVibration()
        startSound(ctx, sound, true)
        startVibration(ctx, vibration, true)
        handler.postDelayed(stopRunnable, 4000)
    }

    fun status(ctx: Context): Map<String, Boolean> {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val notifications = nm?.areNotificationsEnabled() ?: true
        val fullScreen = if (Build.VERSION.SDK_INT >= 34) (nm?.canUseFullScreenIntent() ?: true) else true
        val battery = if (Build.VERSION.SDK_INT >= 23) (pm?.isIgnoringBatteryOptimizations(ctx.packageName) ?: false) else true
        return mapOf("notifications" to notifications, "fullScreen" to fullScreen, "battery" to battery)
    }

    private fun stopSoundAndVibration() {
        handler.removeCallbacks(stopRunnable)
        try {
            player?.stop()
        } catch (e: Exception) {
        }
        try {
            player?.release()
        } catch (e: Exception) {
        }
        player = null
        appContext?.let { vibrator(it)?.cancel() }
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (e: Exception) {
        }
        wakeLock = null
    }

    @Suppress("DEPRECATION")
    private fun wakeScreen(ctx: Context) {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        try {
            val wl = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                "SokoRider:request"
            )
            wl.acquire(30_000L)
            wakeLock = wl
        } catch (e: Exception) {
        }
    }

    private fun showNotification(ctx: Context, title: String, body: String) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val open = Intent(ctx, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_ALERT, true)
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= 23) flags = flags or PendingIntent.FLAG_IMMUTABLE
        val pi = PendingIntent.getActivity(ctx, 4711, open, flags)
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(ctx, CHANNEL_ID)
        else Notification.Builder(ctx).setPriority(Notification.PRIORITY_MAX)
        b.setSmallIcon(ctx.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setFullScreenIntent(pi, true)
        try {
            nm.notify(NOTIF_ID, b.build())
        } catch (e: SecurityException) {
            // Notifications not allowed: the sound, vibration and screen wake still run.
        }
    }

    private fun soundUri(ctx: Context, name: String): Uri? = when (name) {
        "ringtone" -> RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        "alarm" -> RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
        "chime" -> chimeUri(ctx)
        else -> null
    }

    private fun chimeUri(ctx: Context): Uri = Uri.parse("android.resource://${ctx.packageName}/raw/soko_request")

    private fun startSound(ctx: Context, name: String, loop: Boolean) {
        val uri = soundUri(ctx, name) ?: return
        if (!playUri(ctx, uri, loop) && name != "chime") playUri(ctx, chimeUri(ctx), loop)
    }

    private fun playUri(ctx: Context, uri: Uri, loop: Boolean): Boolean = try {
        val mp = MediaPlayer()
        mp.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
        )
        mp.setDataSource(ctx, uri)
        mp.isLooping = loop
        mp.prepare()
        mp.start()
        player = mp
        true
    } catch (e: Exception) {
        false
    }

    private fun vibrator(ctx: Context): Vibrator? = if (Build.VERSION.SDK_INT >= 31) {
        (ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        ctx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }

    @Suppress("DEPRECATION")
    private fun startVibration(ctx: Context, name: String, repeat: Boolean) {
        val pattern = PATTERNS[name] ?: return
        val v = vibrator(ctx) ?: return
        val rep = if (repeat) 0 else -1
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                v.vibrate(
                    VibrationEffect.createWaveform(pattern, rep),
                    VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM)
                )
            } else if (Build.VERSION.SDK_INT >= 26) {
                v.vibrate(
                    VibrationEffect.createWaveform(pattern, rep),
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
                )
            } else {
                v.vibrate(pattern, rep)
            }
        } catch (e: Exception) {
        }
    }
}
