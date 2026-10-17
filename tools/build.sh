#!/bin/bash
# Builds mdinstall, the helper that installs apps on (and reads logs from) old iOS devices.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FRAMEWORKS=/Library/Apple/System/Library/PrivateFrameworks

xcrun clang -Wall -O2 "$HERE/mdinstall.c" -F"$FRAMEWORKS" -framework MobileDevice -framework CoreFoundation \
    -o "$HERE/mdinstall"
echo "Built: $HERE/mdinstall"
