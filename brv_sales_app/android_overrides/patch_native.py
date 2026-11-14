"""Native Android setup for BRV Pos Sales (run from brv_sales_app/ after flutter create).

Reuses BRV POS's MainActivity (channel "brv/print": built-in handheld printer, Bluetooth ESC/POS printers,
Android printing, PDF, backup file save/pick) with this app's package name, label and Downloads folder.
"""
import glob, re

main = glob.glob('android/app/src/main/kotlin/**/MainActivity.kt', recursive=True)[0]
pkg = re.search(r'^package\s+(\S+)', open(main).read(), re.M).group(1)
proj = pkg.rsplit('.', 1)[-1]
src = open('../brv_pos/android_overrides/patch_native.py').read()
src = src.replace('package ke.co.brivatech.brv_pos', 'package ' + pkg)
src = src.replace('"/BRV POS"', '"/BRV Pos Sales"').replace('"BRV POS/Backups"', '"BRV Pos Sales/Backups"')
src = src.replace("""c = c.replace('android:label="brv_pos"', 'android:label="BRV POS"')""",
                  """c = c.replace('android:label="%s"', 'android:label="BRV Pos Sales"')""" % proj)
exec(compile(src, 'brv_pos_patch_native', 'exec'))
print('package', pkg, 'label BRV Pos Sales')
