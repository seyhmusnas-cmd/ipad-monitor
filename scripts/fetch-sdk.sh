#!/bin/bash
# Downloads the iOS 9.3 SDK and patches it so today's Xcode can link 32-bit (armv7) apps against it.
#
# Current Xcode can still *compile* armv7, but its iOS SDK no longer contains armv7 stubs to link
# against. The iOS 9.3 SDK from the theos/sdks project (headers and .tbd text stubs only, no binaries
# beyond Apple's standard crt objects) fills that gap. It isn't committed to this repo because it
# contains Apple's files.
#
# The new linker also misreads the old .tbd files: because they list i386/x86_64 next to the
# ARM architectures, it treats them as Simulator libraries and refuses to link. The patched copy
# simply drops the Intel architectures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
ORIGINAL="$VENDOR/theos-sdks/iPhoneOS9.3.sdk"
PATCHED="$VENDOR/iPhoneOS9.3-armv7.sdk"

mkdir -p "$VENDOR"
if [ ! -d "$ORIGINAL" ]; then
    echo "Downloading iPhoneOS9.3.sdk from github.com/theos/sdks (about 56 MB)…"
    git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git "$VENDOR/theos-sdks"
    git -C "$VENDOR/theos-sdks" sparse-checkout set iPhoneOS9.3.sdk
fi

echo "Patching a copy for the current linker…"
rm -rf "$PATCHED"
cp -R "$ORIGINAL" "$PATCHED"
find "$PATCHED" -name '*.tbd' -print0 | xargs -0 perl -pi -e 's/,\s*(i386|x86_64)\b//g; s/\[\s*(i386|x86_64)\s*,\s*/[ /g'

echo "Ready: $PATCHED"
