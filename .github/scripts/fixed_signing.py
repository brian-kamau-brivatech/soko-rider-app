"""Sign the release APK with the fixed BRV key (GitHub secrets), so every new build installs over the old one.

Without one fixed key Android refuses the update ("App not installed"). Android's default debug key is created
fresh on each build machine, so it is never used here: the generated android/app/build.gradle(.kts) is
pointed at the key from the secrets instead. Run from the Flutter project folder, after `flutter create`.
Secrets: BRV_KEYSTORE_BASE64 (the .p12 / .jks file, base64), BRV_KEYSTORE_PASSWORD (alias 'brv').
"""
import base64, os, pathlib, sys

b64 = os.environ.get('BRV_KEYSTORE_BASE64', '').strip()
pw = os.environ.get('BRV_KEYSTORE_PASSWORD', '').strip()
if not b64 or not pw:
    print('::error::The fixed signing key is not set (GitHub secrets BRV_KEYSTORE_BASE64 and BRV_KEYSTORE_PASSWORD). '
          'Stopping: an APK with a random key cannot update the installed app.')
    sys.exit(1)
ks = pathlib.Path(os.environ.get('RUNNER_TEMP', '/tmp')) / 'brv-signing.p12'
ks.write_bytes(base64.b64decode(''.join(b64.split())))
env_file = os.environ.get('GITHUB_ENV')
if env_file:
    with open(env_file, 'a') as f:  # for the Gradle build in the later steps (GitHub hides the secret in logs)
        f.write('BRV_KEYSTORE_PATH=%s\n' % ks)
        f.write('BRV_KEYSTORE_PASSWORD=%s\n' % pw)

kts = pathlib.Path('android/app/build.gradle.kts')
groovy = pathlib.Path('android/app/build.gradle')
if kts.exists():
    t = kts.read_text()
    block = '''    signingConfigs {
        create("brv") {
            storeFile = file(System.getenv("BRV_KEYSTORE_PATH"))
            storePassword = System.getenv("BRV_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("BRV_KEY_ALIAS") ?: "brv"
            keyPassword = System.getenv("BRV_KEYSTORE_PASSWORD")
        }
    }

    buildTypes {'''
    assert '    buildTypes {' in t, 'buildTypes not found in build.gradle.kts'
    t = t.replace('    buildTypes {', block, 1)
    t = t.replace('signingConfig = signingConfigs.getByName("debug")', 'signingConfig = signingConfigs.getByName("brv")')
    assert 'signingConfigs.getByName("brv")' in t, 'release signingConfig not found in build.gradle.kts'
    kts.write_text(t)
    print('Release build signed with the fixed BRV key (build.gradle.kts)')
elif groovy.exists():
    t = groovy.read_text()
    block = '''    signingConfigs {
        brv {
            storeFile file(System.getenv("BRV_KEYSTORE_PATH"))
            storePassword System.getenv("BRV_KEYSTORE_PASSWORD")
            keyAlias System.getenv("BRV_KEY_ALIAS") ?: "brv"
            keyPassword System.getenv("BRV_KEYSTORE_PASSWORD")
        }
    }

    buildTypes {'''
    t = t.replace('    buildTypes {', block, 1)
    t = t.replace('signingConfig signingConfigs.debug', 'signingConfig signingConfigs.brv')
    assert 'signingConfigs.brv' in t, 'release signingConfig not found in build.gradle'
    groovy.write_text(t)
    print('Release build signed with the fixed BRV key (build.gradle)')
else:
    print('::error::android/app/build.gradle(.kts) not found')
    sys.exit(1)
