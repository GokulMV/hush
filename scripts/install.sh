#!/usr/bin/env bash
# Clean install: build, quit and delete any old copy (and the old CallGuard), install fresh, launch.
# Usage:  git pull && ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

echo "Removing old copies…"
for name in Hush CallGuard; do
    if pgrep -x "$name" >/dev/null; then
        osascript -e "quit app \"$name\"" >/dev/null 2>&1 || true
        sleep 1
        pkill -x "$name" >/dev/null 2>&1 || true
    fi
    rm -rf "/Applications/$name.app"
done

# Every build has a new signature, so macOS silently ignores the old Accessibility ✓ for Hush.
# Clearing it makes Hush ask again cleanly on launch instead of failing quietly.
tccutil reset Accessibility com.gokulmv.hush >/dev/null 2>&1 || true
tccutil reset All com.gokulmv.callguard >/dev/null 2>&1 || true

# The old name may live on elsewhere (e.g. a build/CallGuard.app that Launchpad and Spotlight
# still list). Find every copy by its bundle ID and delete it.
rm -rf build/CallGuard.app
mdfind "kMDItemCFBundleIdentifier == 'com.gokulmv.callguard'" 2>/dev/null | while IFS= read -r old; do
    [ -n "$old" ] && [ -d "$old" ] && rm -rf "$old" && echo "Removed $old"
done

cp -R build/Hush.app /Applications/
open /Applications/Hush.app

echo
echo "✅ Hush installed fresh in /Applications and launched."
echo "   When asked, allow Accessibility (System Settings → Privacy & Security → Accessibility → Hush)."
