#!/bin/bash
# Builds the iPad app (iOS 9, 32-bit armv7) with a current Xcode, signs it, and optionally installs it.
#
# Usage:  ./build.sh                                 -> unsigned build in build/Payload/Monitor.app
#         ./build.sh <profile.mobileprovision>       -> signed build + build/Monitor.ipa
#         ./build.sh <profile.mobileprovision> install   -> also installs on the first iPad on USB
#
# Needs the patched iOS 9.3 SDK from ../scripts/fetch-sdk.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
SDK="$ROOT/vendor/iPhoneOS9.3-armv7.sdk"
OUT="$HERE/build"
APP="$OUT/Payload/Monitor.app"
BUNDLE_ID="${BUNDLE_ID:-com.example.ipadmonitor}"  # only used with a wildcard profile
PROFILE="${1:-}"

if [ ! -d "$SDK" ]; then
    echo "Missing $SDK — run scripts/fetch-sdk.sh first." >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$APP"

# Today's clang still generates armv7 code; we link against the old SDK.
# -marm: the new linker doesn't set the low "Thumb" bit on the entry point of Thumb functions
#        (the app dies with SIGILL on launch), so all code is generated in ARM mode instead.
# -fno-objc-msgsend-selector-stubs: don't rely on linker-generated armv7 stubs either.
xcrun clang -target armv7-apple-ios9.0 -isysroot "$SDK" \
    -marm -fno-objc-msgsend-selector-stubs \
    -fobjc-arc -Os -Wall \
    "$HERE"/*.m \
    -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore -framework AVFoundation -framework CoreMedia \
    -o "$APP/Monitor" 2> >(grep -v "liblaunch.dylib" >&2)

if [ -n "$PROFILE" ]; then
    security cms -D -i "$PROFILE" > "$OUT/profile.plist"
    TEAM=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$OUT/profile.plist")
    APPID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$OUT/profile.plist")
    # With an explicit App ID the bundle ID comes from the profile; with a wildcard we use our own.
    if [[ "$APPID" != *"*" ]]; then BUNDLE_ID="${APPID#"$TEAM".}"; fi

    /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$OUT/profile.plist" > "$OUT/entitlements.plist"
    /usr/libexec/PlistBuddy -c "Set :application-identifier $TEAM.$BUNDLE_ID" "$OUT/entitlements.plist"
    /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$OUT/entitlements.plist" 2>/dev/null || true
    cp "$PROFILE" "$APP/embedded.mobileprovision"

    # Sign with the profile's certificate that's actually in the keychain (unless IDENTITY is set).
    if [ -z "${IDENTITY:-}" ]; then
        IDENTITIES=$(security find-identity -v -p codesigning)
        i=0
        while CERT=$(plutil -extract "DeveloperCertificates.$i" raw -o - "$OUT/profile.plist" 2>/dev/null); do
            HASH=$(base64 -D <<< "$CERT" | shasum -a 1 | cut -d' ' -f1 | tr a-f A-F)
            if grep -q "$HASH" <<< "$IDENTITIES"; then IDENTITY="$HASH"; break; fi
            i=$((i + 1))
        done
        if [ -z "${IDENTITY:-}" ]; then
            echo "None of the profile's certificates are in your keychain." >&2
            exit 1
        fi
    fi
fi

sed "s/__BUNDLE_ID__/$BUNDLE_ID/" "$HERE/Info.plist" > "$APP/Info.plist"
plutil -convert binary1 "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"

if [ -n "$PROFILE" ]; then
    codesign -f -s "$IDENTITY" --entitlements "$OUT/entitlements.plist" "$APP"
    (cd "$OUT" && zip -qry Monitor.ipa Payload)
    echo "Built and signed: $OUT/Monitor.ipa ($BUNDLE_ID)"
else
    echo "Built (unsigned): $APP"
fi

if [ "${2:-}" = "install" ]; then
    [ -x "$ROOT/tools/mdinstall" ] || "$ROOT/tools/build.sh"
    "$ROOT/tools/mdinstall" install - "$APP"
fi
