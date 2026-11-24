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
import binascii, subprocess


def unb64(s):
    try:
        return base64.b64decode(''.join(s.split()), validate=False)
    except (binascii.Error, ValueError):
        return b''


def is_keystore(data):
    return len(data) > 500 and data[:1] == b'\x30'  # a PKCS12 / JKS key file is binary and starts with 0x30


raw = unb64(b64)
if not is_keystore(raw):
    if is_keystore(unb64(raw.decode('latin-1'))):  # pasted base64 twice
        raw = unb64(raw.decode('latin-1'))
        print('Note: the key secret was base64 twice; decoded it twice.')
    elif is_keystore(unb64(pw)):  # the two secrets were swapped
        raw, pw = unb64(pw), b64
        print('Note: BRV_KEYSTORE_BASE64 and BRV_KEYSTORE_PASSWORD were swapped; using them the right way round.')
print('Key secret: %d characters -> %d bytes, starts with %s; password secret: %d characters'
      % (len(b64), len(raw), raw[:1].hex() or '(nothing)', len(pw)))
if not is_keystore(raw):
    print('::error::BRV_KEYSTORE_BASE64 does not hold the key file. On the Mac run: '
          'base64 -i ~/BRV_signing_key/brv-signing.p12 | pbcopy  then edit the secret BRV_KEYSTORE_BASE64 on GitHub '
          'and paste (Cmd+V). The password secret must be the text of ~/BRV_signing_key/password.txt (32 characters).')
    sys.exit(1)
ks = pathlib.Path(os.environ.get('RUNNER_TEMP', '/tmp')) / 'brv-signing.p12'
ks.write_bytes(raw)
chk = subprocess.run(['keytool', '-list', '-keystore', str(ks), '-storetype', 'PKCS12', '-storepass', pw, '-alias', 'brv'],
                     capture_output=True, text=True)
if chk.returncode != 0:
    msg = [l for l in (chk.stdout + chk.stderr).replace(pw, '***').splitlines() if 'error' in l.lower() and '_JAVA_OPTIONS' not in l]
    print('::error::The key file was found but cannot be opened with BRV_KEYSTORE_PASSWORD (%s). Edit the secret '
          'BRV_KEYSTORE_PASSWORD on GitHub: on the Mac run  pbcopy < ~/BRV_signing_key/password.txt  and paste.'
          % (msg[-1] if msg else 'no detail'))
    sys.exit(1)
fp = [l for l in chk.stdout.splitlines() if 'SHA-256' in l or 'SHA256' in l]
print('Fixed BRV key opened: %s' % (fp[0].strip() if fp else 'alias brv'))
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
