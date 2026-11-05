import Foundation
import ModelStoreKit

extension AppServices {
    /// Another app can remove what this one verified earlier, so old evidence goes
    /// when the store changes. Checking again is cheap for files that did not change.
    func startWatchingSharedModels() {
        Task(priority: .utility) { [modelStore, modelLifecycle] in
            for await _ in modelStore.changes() {
                for descriptor in ModelCatalog.all {
                    await modelLifecycle.invalidate(descriptor)
                }
            }
        }
    }

    func installedModels() async -> [ModelStore.InstalledModel] {
        await modelStore.installedModels()
    }

    func sharedModelChanges() -> AsyncStream<Void> {
        modelStore.changes()
    }

    /// One small model that a second app also claims, in the disposable store only.
    func seedSharedModelFixtureIfRequested() {
        guard usesTemporaryMeetingStore,
              ProcessInfo.processInfo.arguments.contains("-seed-shared-model") else { return }
        Task { [modelStore] in
            guard let descriptor = try? Self.sharedModelFixture() else { return }
            let otherApp = ModelStore(
                rootDirectory: Self.temporaryModelRoot,
                consumer: .init(identifier: "app.other.fixture", displayName: "Secreteo"))
            _ = try? await otherApp.ensureAvailable(descriptor)
            _ = try? await modelStore.ensureAvailable(descriptor)
        }
    }

    private static func sharedModelFixture() throws -> ModelDescriptor {
        let source = temporaryModelRoot.deletingLastPathComponent()
            .appendingPathComponent("portavoz-uitest-model-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("portavoz".utf8)
        try bytes.write(to: source.appendingPathComponent("weights.bin"))
        return ModelDescriptor(
            id: "shared-fixture", tasks: [.liveTranscription], displayName: "Shared test model",
            folderName: "shared-fixture", resolveBase: source, revision: "fixture",
            artifacts: [ModelArtifact(
                path: "weights.bin",
                sha256: "4ecee2919ab9629b61d4543de22401e3cef9ae41a11bf1244338eeaee3b34809",
                sizeBytes: bytes.count)],
            minimumRAMGB: 0, license: "fixture")
    }
}
