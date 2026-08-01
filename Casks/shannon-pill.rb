cask "shannon-pill" do
  version "2.1.0"
  # NOT production-ready until `scripts/package_pill.sh --update-cask` writes a
  # real sha after publishing Shannon-<version>.zip. All-zero sha256 is deliberate:
  # Homebrew will refuse a remote cask install rather than silently fetching junk.
  # Local path (recommended while unsigned): ./scripts/package_pill.sh --install
  # Digest of the published GitHub release asset (not a local rebuild):
  #   curl -fsSL .../v2.1.0/Shannon-2.1.0.zip | shasum -a 256
  sha256 "16a029b7f2b85b2611bea0b2a02573357adae3b6b97470a3327d7f357793aea4"

  # ZIP is the cask asset (reproducible sha256). DMG is also published for humans.
  url "https://github.com/LeBonhommePharma/Shannon/releases/download/v#{version}/Shannon-#{version}.zip",
      verified: "github.com/LeBonhommePharma/Shannon/"
  name "Shannon UI"
  desc "Shannon UI — macOS menu-bar / notch operator HUD (ShannonPill)"
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
    Shannon UI (this cask) is the sole shipped macOS operator HUD (LSUIElement):
    it does not show a Dock icon. Headless entropy/gate/agent tools are Shannon CLI
    (Homebrew formula `shannon`, pip `shannon-entropy`, hub/).

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
