#!/bin/bash
# Builds Silt.app from the Swift package. Needs only the Command Line Tools, not Xcode.
#   ./build.sh            → build/Silt.app
#   ./build.sh --install  → builds it and moves it to /Applications
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Silt
swift build -c release --product silt-scan
BIN="$(swift build -c release --show-bin-path)"

APP=build/Silt.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Silt" "$APP/Contents/MacOS/Silt"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon: draw once at 1024 px, then let sips and iconutil make the sizes macOS wants.
if [ ! -f build/Silt.icns ] || [ icon/make-icon.swift -nt build/Silt.icns ]; then
    ICONSET=build/Silt.iconset
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    swift icon/make-icon.swift build/icon-1024.png >/dev/null
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o build/Silt.icns
fi
cp build/Silt.icns "$APP/Contents/Resources/Silt.icns"

# Ad-hoc signature: enough for Apple silicon to run it. macOS ties privacy grants (Full Disk
# Access) to the signature, so after a rebuild you may need to grant it again.
codesign --force --sign - --timestamp=none "$APP"

if [ "${1:-}" = "--install" ]; then
    # Moved, not copied: two identical copies both show up in Spotlight, and macOS may
    # reopen the wrong one when it relaunches Silt after Full Disk Access is granted.
    rm -rf /Applications/Silt.app
    mv "$APP" /Applications/Silt.app
    echo "Installed /Applications/Silt.app"
else
    echo "Built $APP"
fi
