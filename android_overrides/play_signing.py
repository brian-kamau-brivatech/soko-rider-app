"""Add the Play Store upload key to the generated Gradle file.

The release build uses the upload key only when UPLOAD_KEYSTORE_PATH is set
(the Play Store App Bundle step). The APK for GitHub keeps the debug key, so
riders who installed it from GitHub can still update it.
"""
import re

p = 'android/app/build.gradle.kts'
s = open(p).read()

signing = '''signingConfigs {
        if (System.getenv("UPLOAD_KEYSTORE_PATH") != null) {
            create("upload") {
                storeFile = file(System.getenv("UPLOAD_KEYSTORE_PATH")!!)
                storePassword = System.getenv("UPLOAD_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("UPLOAD_KEY_ALIAS")
                keyPassword = System.getenv("UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {'''
s, n = re.subn(r'buildTypes\s*\{', signing, s, count=1)
assert n == 1, 'buildTypes block not found in ' + p

old = 'signingConfig = signingConfigs.getByName("debug")'
assert old in s, 'debug signingConfig line not found in ' + p
s = s.replace(old, 'signingConfig = if (System.getenv("UPLOAD_KEYSTORE_PATH") != null) '
                   'signingConfigs.getByName("upload") else signingConfigs.getByName("debug")', 1)

# Google Play: new apps and updates must target Android 16 (API 36).
s = re.sub(r'targetSdk\s*=\s*flutter\.targetSdkVersion', 'targetSdk = maxOf(flutter.targetSdkVersion, 36)', s)
s = re.sub(r'compileSdk\s*=\s*flutter\.compileSdkVersion', 'compileSdk = maxOf(flutter.compileSdkVersion, 36)', s)
open(p, 'w').write(s)
print(s)
