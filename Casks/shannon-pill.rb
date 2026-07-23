cask "shannon-pill" do
  version "0.1.0"
  # Filled by `scripts/package_pill.sh --update-cask` or release CI.
  # Zeros intentionally reject installs until a real artifact is published.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  # ZIP is the cask asset (reproducible sha256). DMG is also published for humans.
  url "https://github.com/LeBonhommePharma/Shannon/releases/download/v#{version}/Shannon-#{version}.zip",
      verified: "github.com/LeBonhommePharma/Shannon/"
  name "Shannon Pill"
  desc "AI agent hub with notch pill interface and entropy collapse monitoring"
  homepage "https://github.com/LeBonhommePharma/Shannon"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  # ZIP root contains Shannon.app (ShannonPill.app renamed by package_pill.sh).
  app "Shannon.app"

  # Agent-style LSUIElement app — no dock icon; quit via pkill or Activity Monitor.
  uninstall quit: "com.lebonhommepharma.shannon.pill"

  zap trash: [
    "~/.shannon",
    "~/Library/Application Support/Shannon",
    "~/Library/Caches/com.lebonhommepharma.shannon.pill",
    "~/Library/Preferences/com.lebonhommepharma.shannon.pill.plist",
    "~/Library/Saved Application State/com.lebonhommepharma.shannon.pill.savedState",
  ]

  caveats <<~EOS
    Shannon Pill is an agent UI (LSUIElement): it does not show a Dock icon.

    First launch after brew install may be blocked by Gatekeeper for unsigned /
    ad-hoc-signed builds. If macOS says the app is damaged or cannot be opened:

      xattr -dr com.apple.quarantine /Applications/Shannon.app
      open /Applications/Shannon.app

    Or right-click the app → Open → Open.

    For a local build without a GitHub release (recommended while unsigned):

      ./scripts/package_pill.sh --install
      # or: ./scripts/install_macos_app.sh

    Production releases should be signed with Developer ID Application and
    notarized; set CODESIGN_IDENTITY / NOTARY_PROFILE when running package_pill.sh.
  EOS
end
