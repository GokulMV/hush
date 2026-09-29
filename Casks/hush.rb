# Written by scripts/release.sh and copied to the tap repo GokulMV/homebrew-hush.
# Install with: brew install --cask gokulmv/hush/hush
cask "hush" do
  version "1.0.1"
  sha256 "88520a86a23a86b756f541eeeec620af9fa26988669a194a34eb48029ab982bb"

  url "https://github.com/GokulMV/hush/releases/download/v#{version}/Hush-#{version}.zip"
  name "Hush"
  desc "Mutes your mic, turns off your camera and pauses videos when you step away or pick up your phone"
  homepage "https://github.com/GokulMV/hush"

  depends_on macos: ">= :ventura"
  depends_on arch: :arm64

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
