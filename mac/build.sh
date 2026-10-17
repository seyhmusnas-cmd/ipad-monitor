#!/bin/bash
# Builds and signs MonitorHost.app.
# It's a separate .app so the macOS Screen Recording and Accessibility permissions belong to it.
#
# Usage:  ./build.sh            -> build/MonitorHost.app
#         ./build.sh run        -> build, quit any running copy, launch from here
#         ./build.sh install    -> build, install to ~/Applications and launch from there
#                                  (needed for "Open at Login")
# Log: ~/Library/Logs/MonitorHost.log
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/MonitorHost.app"
HOST_BUNDLE_ID="${HOST_BUNDLE_ID:-com.sehmus.monitorhost}"

# Sign with a stable certificate if there is one, so macOS keeps the permissions across rebuilds.
# Without one we fall back to ad-hoc signing; then you'll need to re-allow the permissions after each build.
if [ -z "${IDENTITY:-}" ]; then
    IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
    IDENTITY="${IDENTITY:--}"
fi

mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -import-objc-header "$HERE/CGVirtualDisplay.h" "$HERE/MonitorHost.swift" \
    -o "$APP/Contents/MacOS/MonitorHost"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$HOST_BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>MonitorHost</string>
	<key>CFBundleExecutable</key>
	<string>MonitorHost</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

codesign -f -s "$IDENTITY" "$APP"
echo "Built: $APP"

case "${1:-}" in
    run)
        pkill -x MonitorHost 2>/dev/null || true
        sleep 1
        open -n "$APP"
        ;;
    install)
        DEST="$HOME/Applications/MonitorHost.app"
        pkill -x MonitorHost 2>/dev/null || true
        sleep 1
        mkdir -p "$HOME/Applications"
        rm -rf "$DEST"
        ditto "$APP" "$DEST"
        open "$DEST"
        echo "Installed: $DEST"
        ;;
esac
if [ -n "${1:-}" ]; then
    sleep 4
    cat "$HOME/Library/Logs/MonitorHost.log"
fi
