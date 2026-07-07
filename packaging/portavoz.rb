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
    Todo el procesamiento (transcripción, diarización, resúmenes) ocurre
    en tu Mac. La primera grabación pedirá permisos de micrófono y de
    "Grabación de pantalla y audio del sistema".
  EOS
end
