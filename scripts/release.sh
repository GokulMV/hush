#!/usr/bin/env bash
# Publishes a Hush release that installs with Homebrew:
#   1. builds Hush.app (Apple Silicon + Intel when Xcode allows), with the phone detector bundled
#   2. uploads Hush-<version>.zip as a GitHub release of this repo
#   3. writes Casks/hush.rb and pushes it to the tap repo <owner>/homebrew-hush (created if missing)
# Afterwards anyone can install with:  brew install --cask <owner>/hush/hush
#
# Usage: ./scripts/release.sh 1.0.0      (needs the GitHub CLI: brew install gh && gh auth login)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: ./scripts/release.sh <version, e.g. 1.0.0>}"
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh && gh auth login"; exit 1; }

# Release notes come from CHANGELOG.md ("## <version> …" section); Hush shows the same text.
NOTES="$(awk -v v="$VERSION" '
    /^## / { if (found) exit; split($2, a, " "); if (a[1] == v || a[1] == "v" v) { found = 1; next } }
    found { print }' CHANGELOG.md)"
if [ -z "$(echo "$NOTES" | tr -d '[:space:]')" ]; then
    echo "Add a \"## $VERSION\" section to CHANGELOG.md first (it becomes the release notes and What's New)."
    exit 1
fi

OWNER="$(gh repo view --json owner -q .owner.login)"
REPO="$(gh repo view --json name -q .name)"
TAP="$OWNER/homebrew-hush"
OWNER_LC="$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')"

echo "▶ Setting version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" Resources/Info.plist
# Where Hush looks for updates.
/usr/libexec/PlistBuddy -c "Set :HushGitHubRepo $OWNER/$REPO" Resources/Info.plist 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :HushGitHubRepo string $OWNER/$REPO" Resources/Info.plist

echo "▶ Building"
UNIVERSAL=1 ./scripts/build-app.sh
[ -s build/Hush.app/Contents/Resources/ObjectDetector.mlmodel ] \
    || echo "⚠️  Phone detector not bundled; the app will download it on first launch."

ZIP="build/Hush-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Hush.app "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

echo "▶ Writing Casks/hush.rb"
mkdir -p Casks
cat > Casks/hush.rb <<CASK
# Written by scripts/release.sh and copied to the tap repo $TAP.
# Install with: brew install --cask $OWNER_LC/hush/hush
cask "hush" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$OWNER/$REPO/releases/download/v#{version}/Hush-#{version}.zip"
  name "Hush"
  desc "Mutes your mic, turns off your camera and pauses videos when you step away or pick up your phone"
  homepage "https://github.com/$OWNER/$REPO"

  depends_on macos: ">= :ventura"

  app "Hush.app"

  # Hush isn't notarized yet; without this macOS refuses to open a downloaded copy.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Hush.app"]
  end

  uninstall quit: "com.gokulmv.hush"

  zap trash: [
    "~/Library/Application Support/Hush",
    "~/Library/Preferences/com.gokulmv.hush.plist",
  ]
end
CASK

echo "▶ Publishing release v$VERSION"
git add Resources/Info.plist Casks/hush.rb CHANGELOG.md
git commit -m "Release $VERSION" || true
git tag -f "v$VERSION"
git push
git push -f origin "v$VERSION"
if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" --clobber
else
    printf '%s\n\n---\nInstall or update with Homebrew: `brew install --cask %s/hush/hush`\n' \
        "$NOTES" "$OWNER_LC" > build/release-notes.md
    gh release create "v$VERSION" "$ZIP" --title "Hush $VERSION" --notes-file build/release-notes.md
fi

echo "▶ Updating tap $TAP"
if ! gh repo view "$TAP" >/dev/null 2>&1; then
    gh repo create "$TAP" --public --description "Homebrew tap for Hush" --add-readme
fi
TAP_DIR="build/tap"
rm -rf "$TAP_DIR"
gh repo clone "$TAP" "$TAP_DIR" -- --depth 1
mkdir -p "$TAP_DIR/Casks"
cp Casks/hush.rb "$TAP_DIR/Casks/hush.rb"
git -C "$TAP_DIR" add Casks/hush.rb
git -C "$TAP_DIR" commit -m "Hush $VERSION" || true
git -C "$TAP_DIR" push

echo
echo "✅ Released Hush $VERSION"
echo "   Install:  brew install --cask $OWNER_LC/hush/hush"
echo "   Update:   brew upgrade --cask hush"
