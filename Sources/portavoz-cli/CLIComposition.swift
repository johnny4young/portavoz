import ApplicationKit
import DiarizationKit
import Foundation
import PlatformKit
import PortavozCore
import StorageKit

/// The sole construction surface for product-facing CLI commands. Commands
/// receive application workflows and retain only parsing and terminal output.
struct CLIComposition {
    let platform: CLIPlatformDependencies
    let store: MeetingStore
    let library: QueryMeetingLibrary
    let ask: AskMeetings

    static func open(
        dbPath: String?,
        platform: CLIPlatformDependencies
    ) throws -> Self {
        let store: MeetingStore
        if let dbPath {
            store = try MeetingStore(databaseURL: URL(fileURLWithPath: dbPath))
        } else {
            store = try MeetingStore(databaseURL: MeetingStore.defaultDatabaseURL)
        }
        return Self(
            platform: platform,
            store: store,
            library: .local(store: store),
            ask: .local(store: store))
    }
}

/// Process-wide concrete platform/security dependencies for CLI product
/// commands. Benchmark harnesses intentionally retain isolated construction.
struct CLIPlatformDependencies {
    let secretStorage: KeychainSecretStore
    let secrets: ManageSecrets
    let voiceprintStore: VoiceprintStore
    let voiceGallery: VoiceGallery

    init() {
        let secretStorage = KeychainSecretStore()
        self.secretStorage = secretStorage
        secrets = ManageSecrets(storage: secretStorage)
        voiceprintStore = VoiceprintStore(secrets: secretStorage)
        voiceGallery = VoiceGallery(secrets: secretStorage)
    }

    /// Keychain is authoritative when it contains a non-empty value. A
    /// temporary Keychain failure or an absent value may still use the
    /// command's explicit environment-variable fallback.
    func credential(
        for identifier: SecretIdentifier,
        environmentVariable: String
    ) async -> String? {
        if let stored = try? await secrets.value(for: identifier),
           !stored.isEmpty {
            return stored
        }
        guard let fallback = ProcessInfo.processInfo.environment[environmentVariable],
              !fallback.isEmpty
        else { return nil }
        return fallback
    }
}
