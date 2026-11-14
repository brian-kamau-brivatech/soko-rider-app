"""Native Android setup for BRV Pos Manager / BRV Pos Sales / BRV Licence (run from brv_sales_app/ after flutter create).

Reuses BRV POS's MainActivity (channel "brv/print": built-in handheld printer, Bluetooth ESC/POS printers you choose,
Android printing, PDF, backup files) with this app's package name, label (APP_LABEL) and Downloads folder.
"""
import glob, os, re

label = os.environ.get('APP_LABEL', 'BRV Pos Sales')
main = glob.glob('android/app/src/main/kotlin/**/MainActivity.kt', recursive=True)[0]
pkg = re.search(r'^package\s+(\S+)', open(main).read(), re.M).group(1)
proj = pkg.rsplit('.', 1)[-1]
src = open('../brv_pos/android_overrides/patch_native.py').read()
src = src.replace('package ke.co.brivatech.brv_pos', 'package ' + pkg)
src = src.replace('"/BRV POS"', '"/%s"' % label).replace('"BRV POS/Backups"', '"%s/Backups"' % label)
src = src.replace("""c = c.replace('android:label="brv_pos"', 'android:label="BRV POS"')""",
                  """c = c.replace('android:label="%s"', 'android:label="%s"')""" % (proj, label))
exec(compile(src, 'brv_pos_patch_native', 'exec'))
print('package', pkg, 'label', label)
