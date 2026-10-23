import AppIntents
import ApplicationKit
import PortavozCore
import StorageKit

/// Saved dictation texts for the Search dictations Shortcut, behind the same
/// agent consent the MCP tools check.
struct AppDictationIntentReader: PortavozDictationReader {
    let store: MeetingStore

    func dictationTexts(matching words: String, limit: Int) async throws -> [String]? {
        let read = try await ReadDictationsForAgents(store: store).execute(
            .init(filter: DictationRecordFilter(query: words), offset: 0, limit: limit))
        switch read {
        case .notAllowed: return nil
        case .allowed(let page): return page.records.map(\.text)
        }
    }
}

extension AppServices {
    func installDictationIntentReader() {
        let reader: any PortavozDictationReader = AppDictationIntentReader(store: store)
        AppDependencyManager.shared.add(dependency: reader)
    }
}
