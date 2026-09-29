# Written by scripts/release.sh and copied to the tap repo GokulMV/homebrew-tap.
# Install with: brew install --cask gokulmv/tap/over-and-out
cask "over-and-out" do
  version "1.1.11"
  sha256 "5d89549c9fe103cbf41ab8a9df26f764043c570399e1d7191bf3e39ca6ab3b78"

  url "https://github.com/GokulMV/hush/releases/download/v#{version}/OverAndOut-#{version}.zip"
  name "Over&Out"
  desc "Mutes your mic, turns off your camera and pauses videos when you step away or pick up your phone"
  homepage "https://github.com/GokulMV/hush"

  depends_on macos: :ventura


  app "Over&Out.app"

  # Declarative steps (Homebrew 7+; the old `postflight do` block is deprecated).
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
