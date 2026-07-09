import Sparkle
import SwiftUI

/// Sparkle 2 auto-updates for the direct-download channel (D10). The
/// feed URL and the EdDSA public key live in Info.plist (make-app.sh);
/// without them Sparkle simply finds no updates — harmless in dev.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

struct CheckForUpdatesCommand: Commands {
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.system.rawValue

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(checkForUpdatesTitle) {
                Updater.shared.checkForUpdates()
            }
        }
    }

    private var checkForUpdatesTitle: String {
        _ = appLanguageRaw  // Re-render commands when the app language changes.
        return L10n.text("Check for updates…")
    }
}
