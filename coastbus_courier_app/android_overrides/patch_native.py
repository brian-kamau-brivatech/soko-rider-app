"""Native Android setup for Coast Bus Courier (run from coastbus_courier_app/ after flutter create).

1. Reuses BRV POS's MainActivity: channel "brv/print" (built-in handheld printer, Bluetooth ESC/POS printer you choose,
   Android printing, PDF) with this app's package, label and Downloads folder.
2. Adds channel "brv/scan" (hardware barcode imager broadcasts: Sunmi, Urovo, Newland, iData, Seuic, Chainway, Honeywell,
   Zebra DataWedge) and "brv/beep" (good / bad scan tone + vibration).
"""
import glob, os, re

label = os.environ.get('APP_LABEL', 'Coast Bus Courier')
main = glob.glob('android/app/src/main/kotlin/**/MainActivity.kt', recursive=True)[0]
pkg = re.search(r'^package\s+(\S+)', open(main).read(), re.M).group(1)
proj = pkg.rsplit('.', 1)[-1]
src = open('../brv_pos/android_overrides/patch_native.py').read()
src = src.replace('package ke.co.brivatech.brv_pos', 'package ' + pkg)
src = src.replace('"/BRV POS"', '"/%s"' % label).replace('"BRV POS/Backups"', '"%s/Backups"' % label)
src = src.replace("""c = c.replace('android:label="brv_pos"', 'android:label="BRV POS"')""",
                  """c = c.replace('android:label="%s"', 'android:label="%s"')""" % (proj, label))
exec(compile(src, 'brv_pos_patch_native', 'exec'))

SCAN = r'''
        // ---- hardware scanner (broadcast mode) and scan tones ----
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "brv/scan").setStreamHandler(object : EventChannel.StreamHandler {
            var rx: android.content.BroadcastReceiver? = null
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                rx = object : android.content.BroadcastReceiver() {
                    override fun onReceive(c: Context?, i: Intent?) {
                        val ex = i?.extras ?: return
                        val keys = listOf("data", "barcode_string", "barcode", "barocode", "SCAN_BARCODE1", "scannerdata", "value",
                            "com.symbol.datawedge.data_string", "decode_data", "scanResult", "code", "result", "text")
                        var v: String? = null
                        for (k in keys) {
                            val x = ex.get(k)
                            if (x is String && x.isNotBlank()) { v = x; break }
                            if (x is ByteArray && x.isNotEmpty()) {
                                val len = ex.getInt("length", x.size)
                                v = String(x, 0, minOf(len, x.size)); break
                            }
                        }
                        val s = v?.trim()?.trim('\u0000')
                        if (!s.isNullOrEmpty()) runOnUiThread { sink?.success(s) }
                    }
                }
                val f = android.content.IntentFilter()
                listOf("com.sunmi.scanner.ACTION_DATA_CODE_RECEIVED", "android.intent.ACTION_DECODE_DATA", "scan.rcv.message",
                    "urovo.rcv.message", "nlscan.action.SCANNER_RESULT", "android.intent.action.SCANRESULT",
                    "com.android.server.scannerservice.broadcast", "com.honeywell.decode.intent.action.EDIT_DATA",
                    "com.symbol.datawedge.api.RESULT_ACTION", "com.brv.courier.SCAN", "com.scanner.broadcast",
                    "com.android.scanner.broadcast", "android.intent.action.SCANNER_BUTTON_UP", "com.ubx.datawedge.SCANNER_DECODE_EVENT"
                ).forEach { f.addAction(it) }
                if (Build.VERSION.SDK_INT >= 33) registerReceiver(rx, f, Context.RECEIVER_EXPORTED) else registerReceiver(rx, f)
            }
            override fun onCancel(args: Any?) {
                rx?.let { try { unregisterReceiver(it) } catch (e: Exception) {} }
                rx = null
            }
        })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "brv/beep").setMethodCallHandler { call, result ->
            try {
                val good = call.method == "good"
                val tg = android.media.ToneGenerator(android.media.AudioManager.STREAM_NOTIFICATION, 100)
                tg.startTone(if (good) android.media.ToneGenerator.TONE_PROP_BEEP else android.media.ToneGenerator.TONE_CDMA_HIGH_PBX_SS, if (good) 120 else 600)
                android.os.Handler(mainLooper).postDelayed({ tg.release() }, 900)
                val vib = getSystemService(Context.VIBRATOR_SERVICE) as android.os.Vibrator?
                if (!good && vib != null) {
                    if (Build.VERSION.SDK_INT >= 26) vib.vibrate(android.os.VibrationEffect.createWaveform(longArrayOf(0, 250, 120, 250), -1))
                    else vib.vibrate(longArrayOf(0, 250, 120, 250), -1)
                }
            } catch (e: Exception) {}
            result.success(null)
        }
'''
kt = open(main).read()
kt = kt.replace('import io.flutter.plugin.common.MethodChannel', 'import io.flutter.plugin.common.MethodChannel\nimport io.flutter.plugin.common.EventChannel', 1)
anchor = 'super.configureFlutterEngine(flutterEngine)'
assert kt.count(anchor) == 1
kt = kt.replace(anchor, anchor + '\n' + SCAN, 1)
open(main, 'w').write(kt)

p = 'android/app/src/main/AndroidManifest.xml'
c = open(p).read()
if 'android.permission.VIBRATE' not in c:
    c = c.replace('<application', '    <uses-permission android:name="android.permission.VIBRATE" />\n    <application', 1)
open(p, 'w').write(c)
print('package', pkg, 'label', label, '+ scanner channel')
