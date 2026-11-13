"""Native Android setup for the Utange apps (run from utange_app/ after flutter create).

Reuses BRV POS's MainActivity (channel "brv/print": built-in printer, Bluetooth and Android printing)
with this app's package name and label. APP_LABEL env sets the label.
"""
import glob, os, re

main = glob.glob('android/app/src/main/kotlin/**/MainActivity.kt', recursive=True)[0]
pkg = re.search(r'^package\s+(\S+)', open(main).read(), re.M).group(1)
label = os.environ.get('APP_LABEL', 'Utange POS')
proj = pkg.rsplit('.', 1)[-1]
src = open('../brv_pos/android_overrides/patch_native.py').read()
src = src.replace('package ke.co.brivatech.brv_pos', 'package ' + pkg)
src = src.replace("""c = c.replace('android:label="brv_pos"', 'android:label="BRV POS"')""",
                  """c = c.replace('android:label="%s"', 'android:label="%s"')""" % (proj, label))
exec(compile(src, 'brv_pos_patch_native', 'exec'))
print('package', pkg, 'label', label)
