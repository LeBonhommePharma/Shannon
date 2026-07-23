# TODO: update url, sha256, and version after first signed release.
# Run scripts/package_pill.sh to build the DMG and get the real sha256.
cask "shannon-pill" do
  # Bump this when a new signed DMG is published to GitHub releases.
  version "0.1.0"

  # Replace with the sha256 printed by scripts/package_pill.sh after upload.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/LeBonhommePharma/Shannon/releases/download/v#{version}/Shannon-#{version}.dmg"
  name "Shannon"
  desc "AI agent hub for macOS — notch pill interface"
  homepage "https://github.com/LeBonhommePharma/Shannon"

  # The DMG contains Shannon.app (produced by scripts/package_pill.sh).
  app "Shannon.app"

  zap trash: [
    "~/.shannon",
    "~/Library/Application Support/Shannon",
    "~/Library/Preferences/com.lebonhommepharma.shannon.plist",
  ]
end
