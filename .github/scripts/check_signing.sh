#!/bin/bash
# Prints the signing key of each APK and stops the release if it is not the fixed BRV key
# (Android only updates an app signed with the same key). Usage: check_signing.sh file.apk [...]
set -e
AS=$(ls "$ANDROID_HOME"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)
[ -n "$AS" ] || { echo "::error::apksigner not found"; exit 1; }
for f in "$@"; do
  out=$("$AS" verify --print-certs "$f")
  echo "$f: $(echo "$out" | grep -m1 'certificate DN')"
  sha=$(echo "$out" | grep -m1 'certificate SHA-256 digest' | awk '{print $NF}')
  echo "  key SHA-256: $sha"
  if echo "$out" | grep -q "CN=Android Debug"; then
    echo "::error::$f is signed with a random Android debug key, not the fixed BRV key. Not releasing it."
    exit 1
  fi
done
