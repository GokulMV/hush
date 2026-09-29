# Written by scripts/release.sh and copied to the tap repo GokulMV/homebrew-tap.
# Install with: brew install --cask gokulmv/tap/over-and-out
cask "over-and-out" do
  version "1.1.6"
  sha256 "91f1d4229a81e4c812c13701f11e6a9212b60015936908e4b28611d88f586329"

  url "https://github.com/GokulMV/hush/releases/download/v#{version}/OverAndOut-#{version}.zip"
  name "Over&Out"
  desc "Mutes your mic, turns off your camera and pauses videos when you step away or pick up your phone"
  homepage "https://github.com/GokulMV/hush"

  depends_on macos: ">= :ventura"
  depends_on arch: :arm64

  app "Over&Out.app"

  # Over&Out isn't notarized yet; without this macOS refuses to open a downloaded copy.
  postflight do
    # The old version's Accessibility ✓ stays visible but no longer applies to the new build;
    # clear it so macOS asks afresh instead of showing a switch that does nothing.
    system_command "/usr/bin/tccutil", args: ["reset", "Accessibility", "com.gokulmv.overandout"],
                   must_succeed: false
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Over&Out.app"]
  end

  uninstall quit: "com.gokulmv.overandout"

  zap trash: [
    "~/Library/Application Support/OverAndOut",
    "~/Library/Preferences/com.gokulmv.overandout.plist",
  ]
end
