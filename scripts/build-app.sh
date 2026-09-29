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

# On-device phone detectors (downloaded once; the app also fetches any missing one by itself).
{ [ -s Resources/ObjectDetector.mlmodel ] && [ -s Resources/PhoneDetectorLarge.mlmodel ]; } \
    || ./scripts/fetch-model.sh || true
for model in ObjectDetector PhoneDetectorLarge; do
    if [ -s "Resources/$model.mlmodel" ]; then
        cp "Resources/$model.mlmodel" "$APP/Contents/Resources/$model.mlmodel"
    else
        echo "⚠️  Building without $model: the app will download it on first launch."
    fi
done
# Sign with the same certificate every time (scripts/setup-signing.sh), so macOS keeps the app's
# permissions across updates. Without it: ad-hoc signature, and permissions are asked again.
SIGN_ID="Over&Out Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --sign "$SIGN_ID" "$APP"
else
    codesign --force --sign - "$APP"
    echo "⚠️  Ad-hoc signed: macOS will ask for permissions again after each update."
    echo "    Run ./scripts/setup-signing.sh once to fix that."
fi

echo "Built $APP"
