"""Native Android setup for the Soko Shop app (run from shop_app/ after flutter create).

Reuses the rider app's ringing code (../android_overrides/MainActivity.kt) and adds:
  - keepAlive: a small foreground service so new orders still ring when the
    screen is locked (the shop device stays on the charger);
  - keepScreenOn: keep the display awake while the app is open;
  - printImage: receipt image straight to the built-in printer service
    (PrinterService "recieptservice" / Sunmi woyou / Nyx), else Android
    printing with a preview;
  - printerInfo: which printer services this handheld has.
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
                    "printHtml" -> {
                        val html = call.argument<String>("html") ?: ""
                        val job = call.argument<String>("name") ?: "Receipt"
                        runOnUiThread { printHtml(job, html) }
                        result.success(true)
                    }
                    "printImage" -> {
                        val png = call.argument<ByteArray>("png")
                        val job = call.argument<String>("name") ?: "Receipt"
                        // auto | dialog | one printer id from printerInfo
                        val choice = call.argument<String>("printer")
                            ?: (if (call.argument<Boolean>("direct") == false) "dialog" else "auto")
                        if (png == null) {
                            result.success("error")
                        } else if (choice == "dialog") {
                            runOnUiThread { printHtml(job, imageHtml(png)) }
                            result.success("dialog")
                        } else {
                            val all = discoverPrinters()
                            val picked = if (choice == "auto") all else all.filter { printerId(it) == choice }.ifEmpty { all }
                            directPrint(png, picked) { kind ->
                                if (kind == "none" || kind == "error") {
                                    printHtml(job, imageHtml(png))
                                    result.success("dialog")
                                } else {
                                    result.success(kind)
                                }
                            }
                        }
                    }
                    "printerInfo" -> {
                        val pm = packageManager
                        val pkgs = try { pm.getInstalledPackages(0).map { it.packageName } } catch (e: Exception) { emptyList<String>() }
                        val words = listOf("print", "woyou", "receipt", "reciept", "nyx", "imin", "sunmi", "ipos", "pos")
                        val hits = pkgs.filter { p -> words.any { p.lowercase().contains(it) } }.sorted()
                        val services = try {
                            pm.queryIntentServices(Intent("android.printservice.PrintService"), 0)
                                .map { it.serviceInfo.packageName + "/" + it.serviceInfo.name }
                        } catch (e: Exception) { emptyList<String>() }
                        val printers = discoverPrinters().map { t ->
                            val app = try { pm.getApplicationLabel(pm.getApplicationInfo(t.first, 0)).toString() } catch (e: Exception) { t.first }
                            val kindName = when (t.third) { "nyx" -> "Built-in printer"; "sunmi" -> "Sunmi printer"; else -> "Printer service" }
                            mapOf("id" to printerId(t), "label" to "$kindName ($app)", "package" to t.first)
                        }
                        result.success(mapOf(
                            "model" to (Build.MANUFACTURER + " " + Build.MODEL),
                            "android" to Build.VERSION.RELEASE,
                            "printers" to printers,
                            "packages" to hits,
                            "printServices" to services
                        ))
                    }
                    else -> result.notImplemented()'''
assert '                    else -> result.notImplemented()' in s
s = s.replace('                    else -> result.notImplemented()', extra, 1)
helper = '''class MainActivity : FlutterActivity() {
    // Receipt printing through Android printing (the handheld's built-in printer service).
    private var printView: android.webkit.WebView? = null

    private fun printHtml(job: String, html: String) {
        val wv = android.webkit.WebView(this)
        wv.webViewClient = object : android.webkit.WebViewClient() {
            override fun onPageFinished(view: android.webkit.WebView, url: String?) {
                val pm = getSystemService(Context.PRINT_SERVICE) as android.print.PrintManager
                val attrs = android.print.PrintAttributes.Builder()
                    .setMediaSize(android.print.PrintAttributes.MediaSize("soko_roll58", "58 mm roll", 2283, 11693))
                    .setMinMargins(android.print.PrintAttributes.Margins.NO_MARGINS)
                    .setColorMode(android.print.PrintAttributes.COLOR_MODE_MONOCHROME)
                    .build()
                pm.print(job, view.createPrintDocumentAdapter(job), attrs)
                printView = null
            }
        }
        wv.loadDataWithBaseURL(null, html, "text/html", "UTF-8", null)
        printView = wv
    }

    private fun imageHtml(png: ByteArray): String {
        val b64 = android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP)
        return "<!doctype html><html><head><meta charset='utf-8'><style>@page{size:58mm auto;margin:0}" +
            "html,body{margin:0;padding:0}img{width:100%;display:block}</style></head><body>" +
            "<img src='data:image/png;base64," + b64 + "'></body></html>"
    }

    // Direct printing through the handheld's printer service (no preview).
    // Binder calls follow the vendors' AIDL files (method order = transaction code).
    private fun printerId(t: Triple<String, String, String>): String = t.third + "@" + t.first

    // Printers the app can print to without a preview: (package, how to bind, kind).
    // Finds re-branded printer apps too (e.g. com.incar.printerservice = Nyx engine).
    private fun discoverPrinters(): List<Triple<String, String, String>> {
        val pm = packageManager
        val out = linkedMapOf<String, Triple<String, String, String>>()
        fun add(pkg: String, spec: String, kind: String) {
            val key = kind + "@" + pkg
            if (!out.containsKey(key)) out[key] = Triple(pkg, spec, kind)
        }
        fun byAction(action: String, kind: String) {
            try {
                for (r in pm.queryIntentServices(Intent(action), 0)) {
                    add(r.serviceInfo.packageName, "cls:" + r.serviceInfo.name + "#" + action, kind)
                }
            } catch (e: Exception) {}
        }
        byAction("net.nyx.printerservice.IPrinterService", "nyx")
        byAction("woyou.aidlservice.jiuiv5.IWoyouService", "sunmi")
        val installed = try { pm.getInstalledPackages(0).map { it.packageName } } catch (e: Exception) { emptyList<String>() }
        for (pkg in installed.filter { it.lowercase().contains("printerservice") }) {
            if (out.containsKey("nyx@" + pkg)) continue
            val services = try {
                pm.getPackageInfo(pkg, android.content.pm.PackageManager.GET_SERVICES).services
            } catch (e: Exception) { null } ?: continue
            for (sv in services) {
                val n = sv.name
                if (n.contains("Plugin") || !n.endsWith("PrinterService")) continue
                add(pkg, "cls:" + n + "#net.nyx.printerservice.IPrinterService", "nyx")
                break
            }
        }
        if (installed.contains("recieptservice.com.recieptservice")) {
            add("recieptservice.com.recieptservice", "cls:recieptservice.com.recieptservice.service.PrinterService", "reciept")
        }
        return out.values.toList()
    }

    private fun directPrint(png: ByteArray, targets: List<Triple<String, String, String>>, done: (String) -> Unit) {
        val bmp = android.graphics.BitmapFactory.decodeByteArray(png, 0, png.size)
        if (bmp == null) { done("error"); return }
        tryPrinter(0, targets, bmp, done)
    }

    private fun tryPrinter(i: Int, targets: List<Triple<String, String, String>>, bmp: android.graphics.Bitmap, done: (String) -> Unit) {
        if (i >= targets.size) { done("none"); return }
        val (pkg, spec, kind) = targets[i]
        var finished = false
        val activity = this
        val conn = object : android.content.ServiceConnection {
            override fun onServiceConnected(name: android.content.ComponentName?, binder: android.os.IBinder?) {
                if (finished || binder == null) return
                finished = true
                val self = this
                Thread {
                    val ok = try {
                        when (kind) {
                            "reciept" -> reflectPrint(pkg, "recieptservice.com.recieptservice.PrinterInterface", binder, bmp)
                            "sunmi" -> sunmiPrint(binder, bmp)
                            else -> (try { reflectNyx(pkg, binder, bmp) } catch (e: Throwable) { false }) || nyxPrint(binder, bmp)
                        }
                    } catch (e: Throwable) { false }
                    activity.runOnUiThread {
                        try { activity.unbindService(self) } catch (e: Exception) {}
                        if (ok) done(kind) else tryPrinter(i + 1, targets, bmp, done)
                    }
                }.start()
            }
            override fun onServiceDisconnected(name: android.content.ComponentName?) {}
        }
        val intent = if (spec.startsWith("cls:")) {
            val body = spec.substring(4)
            val cls = body.substringBefore("#")
            val action = if (body.contains("#")) body.substringAfter("#") else null
            (if (action != null) Intent(action) else Intent()).setClassName(pkg, cls)
        } else {
            Intent(spec).setPackage(pkg)
        }
        if (kind == "reciept") {
            try { startService(intent) } catch (e: Exception) {}
        }
        val bound = try {
            bindService(intent, conn, Context.BIND_AUTO_CREATE)
        } catch (e: Exception) { false }
        if (!bound) {
            try { unbindService(conn) } catch (e: Exception) {}
            tryPrinter(i + 1, targets, bmp, done)
            return
        }
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            if (!finished) {
                finished = true
                try { unbindService(conn) } catch (e: Exception) {}
                tryPrinter(i + 1, targets, bmp, done)
            }
        }, 4000)
    }

    // Nyx engine through its own interface class (works for re-branded apps).
    private fun reflectNyx(pkg: String, binder: android.os.IBinder, bmp: android.graphics.Bitmap): Boolean {
        val pctx = createPackageContext(pkg, Context.CONTEXT_INCLUDE_CODE or Context.CONTEXT_IGNORE_SECURITY)
        val stub = pctx.classLoader.loadClass("net.nyx.printerservice.print.IPrinterService" + '$' + "Stub")
        val api = stub.getMethod("asInterface", android.os.IBinder::class.java).invoke(null, binder) ?: return false
        val methods = api.javaClass.methods
        val print = methods.firstOrNull { it.name == "printBitmap" && it.parameterTypes.size == 3 } ?: return false
        for (part in slices(bmp)) {
            val r = print.invoke(api, part, 0, 1)
            if (r is Int && r != 0) return false
        }
        methods.firstOrNull { it.name == "paperOut" && it.parameterTypes.size == 1 }?.invoke(api, 80)
        return true
    }

    private fun binderCall(b: android.os.IBinder, descriptor: String, index: Int, fill: (android.os.Parcel) -> Unit): android.os.Parcel? {
        val data = android.os.Parcel.obtain()
        val reply = android.os.Parcel.obtain()
        try {
            data.writeInterfaceToken(descriptor)
            fill(data)
            b.transact(android.os.IBinder.FIRST_CALL_TRANSACTION + index, data, reply, 0)
            reply.readException()
            return reply
        } finally {
            data.recycle()
        }
    }

    // Slices of the receipt, so each Binder call stays small.
    private fun slices(bmp: android.graphics.Bitmap): List<android.graphics.Bitmap> {
        val out = mutableListOf<android.graphics.Bitmap>()
        var y = 0
        while (y < bmp.height) {
            val h = minOf(256, bmp.height - y)
            out.add(android.graphics.Bitmap.createBitmap(bmp, 0, y, bmp.width, h))
            y += h
        }
        return out
    }

    // Printer apps whose interface file is not published: load the interface
    // from the printer app itself and call its methods by name.
    private fun reflectPrint(pkg: String, ifaceName: String, binder: android.os.IBinder, bmp: android.graphics.Bitmap): Boolean {
        val pctx = createPackageContext(pkg, Context.CONTEXT_INCLUDE_CODE or Context.CONTEXT_IGNORE_SECURITY)
        val stub = pctx.classLoader.loadClass(ifaceName + '$' + "Stub")
        val api = stub.getMethod("asInterface", android.os.IBinder::class.java).invoke(null, binder) ?: return false
        val methods = api.javaClass.methods
        fun call(name: String, vararg args: Any?): Boolean {
            val m = methods.firstOrNull { it.name == name && it.parameterTypes.size == args.size } ?: return false
            m.invoke(api, *args)
            return true
        }
        call("beginWork")
        call("setAlignment", 1)
        var printed = false
        for (part in slices(bmp)) {
            if (call("printBitmap", part)) printed = true else break
        }
        if (!printed) return false
        call("nextLine", 3)
        call("endWork")
        return true
    }

    // IWoyouService: 3 printerInit, 9 lineWrap, 11 setAlignment, 17 printBitmap.
    private fun sunmiPrint(b: android.os.IBinder, bmp: android.graphics.Bitmap): Boolean {
        val d = "woyou.aidlservice.jiuiv5.IWoyouService"
        binderCall(b, d, 3) { it.writeStrongBinder(null) }?.recycle()
        binderCall(b, d, 11) { it.writeInt(1); it.writeStrongBinder(null) }?.recycle()
        for (part in slices(bmp)) {
            binderCall(b, d, 17) { it.writeInt(1); part.writeToParcel(it, 0); it.writeStrongBinder(null) }?.recycle()
        }
        binderCall(b, d, 9) { it.writeInt(3); it.writeStrongBinder(null) }?.recycle()
        return true
    }

    // IPrinterService (Nyx): 3 getPrinterStatus, 4 paperOut(px), 10 printBitmap(bitmap, type, align).
    private fun nyxPrint(b: android.os.IBinder, bmp: android.graphics.Bitmap): Boolean {
        val d = "net.nyx.printerservice.print.IPrinterService"
        for (part in slices(bmp)) {
            val r = binderCall(b, d, 10) { it.writeInt(1); part.writeToParcel(it, 0); it.writeInt(0); it.writeInt(1) }
            val code = r?.readInt() ?: -1
            r?.recycle()
            if (code != 0) return false
        }
        binderCall(b, d, 4) { it.writeInt(80) }?.recycle()
        return true
    }
'''
assert 'class MainActivity : FlutterActivity() {' in s
s = s.replace('class MainActivity : FlutterActivity() {\n', helper, 1)
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
         'FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_SPECIAL_USE', 'QUERY_ALL_PACKAGES']
tags = ''.join('    <uses-permission android:name="android.permission.%s" />\n' % x
               for x in perms if ('permission.%s"' % x) not in c)
c = c.replace('<application', tags + '    <application', 1)
svc = ('        <service android:name=".KeepAliveService" android:exported="false"'
       ' android:foregroundServiceType="specialUse">\n'
       '            <property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"'
       ' android:value="Shop counter device that must ring for new customer orders" />\n'
       '        </service>\n')
c = c.replace('</application>', svc + '    </application>', 1)
intents = ('        <intent><action android:name="android.intent.action.DIAL" /><data android:scheme="tel" /></intent>\n'
           '        <intent><action android:name="android.printservice.PrintService" /></intent>\n'
           '        <package android:name="recieptservice.com.recieptservice" />\n'
           '        <package android:name="woyou.aidlservice.jiuiv5" />\n'
           '        <package android:name="net.nyx.printerservice" />\n'
           '        <package android:name="com.incar.printerservice" />\n'
           '        <intent><action android:name="net.nyx.printerservice.IPrinterService" /></intent>\n'
           '        <package android:name="com.iposprinter.iposprinterservice" />\n')
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
