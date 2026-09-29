# Written by scripts/release.sh and copied to the tap repo GokulMV/homebrew-tap.
# Install with: brew install --cask gokulmv/tap/over-and-out
cask "over-and-out" do
  version "1.1.1"
  sha256 "c63e5a0834951b1561c02aa29834a929e0dfbb5174faf70d37c34e63e26de8cc"

  url "https://github.com/GokulMV/hush/releases/download/v#{version}/OverAndOut-#{version}.zip"
  name "Over&Out"
  desc "Mutes your mic, turns off your camera and pauses videos when you step away or pick up your phone"
  homepage "https://github.com/GokulMV/hush"

  depends_on macos: ">= :ventura"
  depends_on arch: :arm64

  app "Over&Out.app"

  # Over&Out isn't notarized yet; without this macOS refuses to open a downloaded copy.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Over&Out.app"]
  end

  uninstall quit: "com.gokulmv.overandout"

  zap trash: [
    "~/Library/Application Support/OverAndOut",
    "~/Library/Preferences/com.gokulmv.overandout.plist",
  ]
end
