#!/usr/bin/env bash
# Clean local install: build, remove any installed copy (and the old Hush / CallGuard builds of this
# app, never someone else's app with the same name), install fresh, launch.
# Usage:  git pull && ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

echo "Removing old copies…"
# Quits and deletes every copy of an app with this bundle ID (Spotlight finds them anywhere).
remove_app() {
    local bundle_id="$1"
    osascript -e "if application id \"$bundle_id\" is running then tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    sleep 1
    mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2>/dev/null | while IFS= read -r old; do
        case "$old" in "$PWD"/build/*) continue ;; esac # keep the fresh build
        [ -n "$old" ] && [ -d "$old" ] && rm -rf "$old" && echo "Removed $old"
    done
}
remove_app com.gokulmv.overandout
remove_app com.gokulmv.hush       # this app's previous name (not the unrelated "Hush" Safari blocker)
remove_app com.gokulmv.callguard  # and the one before that
rm -rf "/Applications/Over&Out.app"

# Every build has a new signature, so macOS silently ignores an old Accessibility ✓.
# Clearing it makes Over&Out ask again cleanly instead of failing quietly.
tccutil reset Accessibility com.gokulmv.overandout >/dev/null 2>&1 || true
tccutil reset All com.gokulmv.hush >/dev/null 2>&1 || true
tccutil reset All com.gokulmv.callguard >/dev/null 2>&1 || true

cp -R "build/Over&Out.app" /Applications/
open "/Applications/Over&Out.app"

echo
echo "✅ Over&Out installed fresh in /Applications and launched."
echo "   When asked, allow Accessibility (System Settings → Privacy & Security → Accessibility → Over&Out)."
