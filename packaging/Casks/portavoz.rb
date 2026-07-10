# Homebrew cask TEMPLATE for Portavoz (D10). The rendered cask lives in
# the centralized tap johnny4young/homebrew-tap; the update-cask.yml
# workflow (or scripts/make-release.sh locally) fills version and sha256.
cask "portavoz" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/johnny4young/portavoz/releases/download/v#{version}/Portavoz-#{version}.dmg"
  name "Portavoz"
  desc "Privacy-first meeting assistant — knows who said what, locally"
  # portavoz.app is parked until the site ships; the repo is the homepage.
  homepage "https://github.com/johnny4young/portavoz"

  auto_updates true
  depends_on macos: :sonoma

  app "Portavoz.app"

  zap trash: [
    "~/Library/Application Support/Portavoz",
  ]

  caveats <<~EOS
    All processing (transcription, diarization, summaries) happens on your Mac.
    The first recording will ask for microphone permission and for
    "Screen & System Audio Recording" permission.
  EOS
end
