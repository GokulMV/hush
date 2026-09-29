#!/usr/bin/env bash
# Builds "Over&Out.app" into ./build (ad-hoc signed, runs locally without a developer account).
# The app's file name has an "&", so always quote it in shells: "build/Over&Out.app".
set -euo pipefail
cd "$(dirname "$0")/.."

# UNIVERSAL=1 builds one app for both Apple Silicon and Intel Macs; used for releases.
# With full Xcode, SwiftPM does it in one go. With only the Command Line Tools, each chip is built
# separately and the two are joined with lipo, which gives the same result.
BINARY=""
if [ "${UNIVERSAL:-0}" = 1 ]; then
    # SEPARATE_ARCHS=1 forces the Command Line Tools route (CI uses it to check that route works).
    if [ "${SEPARATE_ARCHS:-0}" != 1 ] && swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
        BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/OverAndOut"
    else
        echo "▶ Building for Apple Silicon and Intel separately (no full Xcode), then joining them"
        MIN_MACOS=13.0
        if swift build -c release --triple "arm64-apple-macosx$MIN_MACOS" \
            && swift build -c release --triple "x86_64-apple-macosx$MIN_MACOS"; then
            ARM="$(swift build -c release --triple "arm64-apple-macosx$MIN_MACOS" --show-bin-path)/OverAndOut"
            INTEL="$(swift build -c release --triple "x86_64-apple-macosx$MIN_MACOS" --show-bin-path)/OverAndOut"
            mkdir -p build
            lipo -create "$ARM" "$INTEL" -output build/OverAndOut-universal
            BINARY="build/OverAndOut-universal"
        else
            echo "⚠️  Couldn't build for both chips; building for this Mac only (the release will say so)."
        fi
    fi
fi
if [ -z "$BINARY" ]; then
    swift build -c release
    BINARY="$(swift build -c release --show-bin-path)/OverAndOut"
fi

APP="build/Over&Out.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/OverAndOut"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"

# The phone detectors are not bundled: Apple states no license for its Core ML model conversions,
# so the app downloads them from Apple itself on first launch (see THIRD_PARTY_NOTICES.md).
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
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
