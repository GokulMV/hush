#!/usr/bin/env bash
# Builds "Over&Out.app" into ./build (ad-hoc signed, runs locally without a developer account).
# The app's file name has an "&", so always quote it in shells: "build/Over&Out.app".
set -euo pipefail
cd "$(dirname "$0")/.."

# UNIVERSAL=1 builds for Apple Silicon and Intel (needs Xcode); used for releases.
if [ "${UNIVERSAL:-0}" = 1 ] && swift build -c release --arch arm64 --arch x86_64; then
    BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    [ "${UNIVERSAL:-0}" = 1 ] && echo "⚠️  Universal build failed (is full Xcode installed?); building for this Mac only."
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi

APP="build/Over&Out.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OverAndOut" "$APP/Contents/MacOS/OverAndOut"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"

# On-device phone detector (downloaded once; the app also fetches it by itself if missing).
[ -s Resources/ObjectDetector.mlmodel ] || ./scripts/fetch-model.sh || true
if [ -s Resources/ObjectDetector.mlmodel ]; then
    cp Resources/ObjectDetector.mlmodel "$APP/Contents/Resources/ObjectDetector.mlmodel"
else
    echo "⚠️  Building without the phone detector: the app will download it on first launch."
fi
codesign --force --sign - "$APP"

echo "Built $APP"
