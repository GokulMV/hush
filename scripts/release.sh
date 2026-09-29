#!/usr/bin/env bash
# Publishes an Over&Out release that installs with Homebrew:
#   1. builds "Over&Out.app" (Apple Silicon + Intel when Xcode allows), with the phone detector bundled
#   2. uploads OverAndOut-<version>.zip as a GitHub release of this repo
#   3. writes Casks/over-and-out.rb and pushes it to the tap repo <owner>/homebrew-tap (created if missing)
# Afterwards anyone can install with:  brew install --cask <owner>/tap/over-and-out
#
# Usage: ./scripts/release.sh 1.0.0      (needs the GitHub CLI: brew install gh && gh auth login)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: ./scripts/release.sh <version, e.g. 1.0.0>}"
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh && gh auth login"; exit 1; }
# Releases must always be signed with the same certificate, or users are asked for permissions again.
if ! security find-identity -p codesigning 2>/dev/null | grep -q "Over&Out Self-Signed"; then
    echo "Run ./scripts/setup-signing.sh once first (keeps users' permissions across updates)."
    exit 1
fi

# Release notes come from CHANGELOG.md ("## <version> …" section); the app shows the same text.
NOTES="$(awk -v v="$VERSION" '
    /^## / { if (found) exit; split($2, a, " "); if (a[1] == v || a[1] == "v" v) { found = 1; next } }
    found { print }' CHANGELOG.md)"
if [ -z "$(echo "$NOTES" | tr -d '[:space:]')" ]; then
    echo "Add a \"## $VERSION\" section to CHANGELOG.md first (it becomes the release notes and What's New)."
    exit 1
fi

OWNER="$(gh repo view --json owner -q .owner.login)"
REPO="$(gh repo view --json name -q .name)"
TAP="$OWNER/homebrew-tap"
CASK="over-and-out"
OWNER_LC="$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')"

echo "▶ Setting version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" Resources/Info.plist
# Where the app looks for updates.
/usr/libexec/PlistBuddy -c "Set :GitHubRepo $OWNER/$REPO" Resources/Info.plist 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :GitHubRepo string $OWNER/$REPO" Resources/Info.plist

echo "▶ Building"
UNIVERSAL=1 ./scripts/build-app.sh
[ -s "build/Over&Out.app/Contents/Resources/ObjectDetector.mlmodel" ] \
    || echo "⚠️  Phone detector not bundled; the app will download it on first launch."

# Without full Xcode the build is Apple Silicon only; say so in the cask so Intel Macs get a clear message.
ARCH_LINE=""
if ! lipo -archs "build/Over&Out.app/Contents/MacOS/OverAndOut" | grep -q x86_64; then
    ARCH_LINE='  depends_on arch: :arm64'
    echo "⚠️  Apple Silicon only this time (the Intel part didn't build; see the messages above)."
fi

ZIP="build/OverAndOut-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "build/Over&Out.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

echo "▶ Writing Casks/$CASK.rb"
mkdir -p Casks
cat > "Casks/$CASK.rb" <<CASK
# Written by scripts/release.sh and copied to the tap repo $TAP.
# Install with: brew install --cask $OWNER_LC/tap/$CASK
cask "$CASK" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$OWNER/$REPO/releases/download/v#{version}/OverAndOut-#{version}.zip"
  name "Over&Out"
  desc "Mutes your mic, turns off your camera and pauses videos when you step away or pick up your phone"
  homepage "https://github.com/$OWNER/$REPO"

  depends_on macos: :ventura
$ARCH_LINE

  app "Over&Out.app"

  # Declarative steps (Homebrew 7+; the old \`postflight do\` block is deprecated).
  postflight_steps do
    # Over&Out isn't notarized yet; without this macOS refuses to open a downloaded copy.
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Over&Out.app"], must_succeed: false
    # The old version's Accessibility ✓ stays visible but no longer applies to the new build;
    # clear it so macOS asks afresh. (Over&Out also does this itself on its first launch after an update.)
    run "/usr/bin/tccutil", args: ["reset", "Accessibility", "com.gokulmv.overandout"], must_succeed: false
  end

  uninstall quit: "com.gokulmv.overandout"

  zap trash: [
    "~/Library/Application Support/OverAndOut",
    "~/Library/Preferences/com.gokulmv.overandout.plist",
  ]
end
CASK

echo "▶ Publishing release v$VERSION"
git add Resources/Info.plist "Casks/$CASK.rb" CHANGELOG.md
git commit -m "Release $VERSION" || true
# Someone (or Claude) may have pushed to this branch while the build ran: bring that in first,
# or the push is refused and the release stops half-way.
BRANCH="$(git branch --show-current)"
git pull --no-rebase --no-edit origin "$BRANCH"
git tag -f "v$VERSION"
git push origin "$BRANCH"
git push -f origin "v$VERSION"
if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" --clobber
else
    if [ -n "$ARCH_LINE" ]; then CHIPS="Apple Silicon Macs only"; else CHIPS="Apple Silicon and Intel Macs"; fi
    printf '%s\n\n---\nInstall with Homebrew (%s, macOS 13+): `brew install --cask %s/tap/%s`\nUpdate: `brew update && brew upgrade --cask %s/tap/%s`\n' \
        "$NOTES" "$CHIPS" "$OWNER_LC" "$CASK" "$OWNER_LC" "$CASK" > build/release-notes.md
    gh release create "v$VERSION" "$ZIP" --title "Over&Out $VERSION" --notes-file build/release-notes.md
fi

echo "▶ Updating tap $TAP"
if ! gh repo view "$TAP" >/dev/null 2>&1; then
    gh repo create "$TAP" --public --description "Homebrew tap for Over&Out and other apps by $OWNER" --add-readme
fi
TAP_DIR="build/tap"
rm -rf "$TAP_DIR"
gh repo clone "$TAP" "$TAP_DIR" -- --depth 1
mkdir -p "$TAP_DIR/Casks"
cp "Casks/$CASK.rb" "$TAP_DIR/Casks/$CASK.rb"
git -C "$TAP_DIR" add "Casks/$CASK.rb"
git -C "$TAP_DIR" commit -m "Over&Out $VERSION" || true
git -C "$TAP_DIR" push

echo
echo "✅ Released Over&Out $VERSION"
echo "   Install:  brew install --cask $OWNER_LC/tap/$CASK"
echo "   Update:   brew upgrade --cask $OWNER_LC/tap/$CASK"
