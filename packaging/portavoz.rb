# Homebrew cask for Portavoz (D10). Lives in the tap
# johnny4young/homebrew-portavoz once the repo goes public;
# scripts/make-release.sh rewrites version and sha256 on every release.
cask "portavoz" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/johnny4young/portavoz/releases/download/v#{version}/Portavoz-#{version}.dmg"
  name "Portavoz"
  desc "Privacy-first meeting assistant — knows who said what, locally"
  homepage "https://portavoz.app"

  auto_updates true
  depends_on macos: ">= :sonoma"

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
