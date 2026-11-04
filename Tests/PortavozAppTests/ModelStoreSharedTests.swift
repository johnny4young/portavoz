import CryptoKit
import Foundation
@testable import ModelStoreKit
import Testing

struct ModelStoreSharedTests {
    private static let portavoz = ModelStore.Consumer(identifier: "app.portavoz.fixture", displayName: "Portavoz")
    private static let other = ModelStore.Consumer(identifier: "app.other.fixture", displayName: "Other App")

    @Test func aCompleteLegacyInstallMovesInWithoutADownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacy()
        let store = fixture.store(Self.portavoz, legacy: true, offline: true)

        let report = await store.verify(fixture.descriptor)
        let installation = await store.verifiedInstallation(fixture.descriptor)

        #expect(report.isComplete)
        #expect(installation?.directory.path.hasPrefix(fixture.storeRoot.path) == true)
        #expect(fixture.legacyFileExists, "the legacy copy stays for an older build")
    }

    @Test func aPartialLegacyInstallNeverStartsADownloadFromACheck() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacy(corrupting: true)
        let store = fixture.store(Self.portavoz, legacy: true)

        let report = await store.verify(fixture.descriptor)

        #expect(!report.isComplete)
        #expect(fixture.storeIsEmpty, "a check placed nothing and downloaded nothing")
    }

    @Test func aModelFromAnotherAppReadsAsMissingUntilThisAppAsksForIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.store(Self.other).ensureAvailable(fixture.descriptor)
        let store = fixture.store(Self.portavoz, offline: true)

        let before = await store.verifiedInstallation(fixture.descriptor)
        let directory = try await store.ensureAvailable(fixture.descriptor)
        let after = await store.verifiedInstallation(fixture.descriptor)

        #expect(before == nil, "presence is not consent")
        #expect(after?.directory == directory, "asking claims it with nothing to download")
    }

    @Test func removingAModelAnotherAppClaimsKeepsItForThatApp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = fixture.store(Self.other)
        let store = fixture.store(Self.portavoz)
        _ = try await other.ensureAvailable(fixture.descriptor)
        _ = try await store.ensureAvailable(fixture.descriptor)

        let outcome = try await store.remove(fixture.descriptor)

        #expect(outcome == .keptForOthers([Self.other.displayName]))
        #expect(await store.verifiedInstallation(fixture.descriptor) == nil)
        #expect(await other.verifiedInstallation(fixture.descriptor) != nil)
    }

    @Test func removingAModelAlsoRemovesItsLegacyCopySoItIsNotAdoptedAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacy()
        let store = fixture.store(Self.portavoz, legacy: true, offline: true)
        _ = await store.verify(fixture.descriptor)

        let outcome = try await store.remove(fixture.descriptor)

        #expect(outcome == .removed)
        #expect(!fixture.legacyFileExists)
        #expect(await store.verifiedInstallation(fixture.descriptor) == nil)
    }

    @Test func collectingUnusedKeepsTheCurrentPinAndWhatOtherAppsClaim() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(Self.portavoz)
        _ = try await store.ensureAvailable(fixture.descriptor)

        try await store.collectUnused(keeping: [fixture.descriptor])

        #expect(await store.verifiedInstallation(fixture.descriptor) != nil)
    }

    @Test func aStoreThatCannotOpenFailsInsteadOfUsingAnotherFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = ModelStore(
            rootDirectory: fixture.storeRoot, consumer: .init(identifier: "../escape", displayName: "Bad"))

        let report = await store.verify(fixture.descriptor)

        #expect(!report.isComplete)
        await #expect(throws: ModelStore.ModelStoreError.self) {
            try await store.ensureAvailable(fixture.descriptor)
        }
        #expect(fixture.storeIsEmpty)
    }

    @Test func theCatalogListsEveryPinAndEachIsAValidSharedManifest() throws {
        let sources = try FileManager.default.contentsOfDirectory(atPath: Self.catalogFolder.path)
            .filter { $0.hasSuffix(".swift") }
            .map { try String(contentsOf: Self.catalogFolder.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        let declared = sources.components(separatedBy: "= ModelDescriptor(").count - 1

        #expect(ModelCatalog.all.count == declared, "a pin outside the list would lose its claim after 14 days")
        #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count)
        for descriptor in ModelCatalog.all {
            #expect(descriptor.manifest.digest.count == 64)
        }
    }

    private static var catalogFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ModelStoreKit", isDirectory: true)
    }

    private struct Fixture {
        let root: URL
        let descriptor: ModelDescriptor
        let offlineDescriptorBase: URL
        var storeRoot: URL { root.appendingPathComponent("store", isDirectory: true) }
        var legacyRoot: URL { root.appendingPathComponent("legacy", isDirectory: true) }
        private var legacyFile: URL {
            legacyRoot.appendingPathComponent(descriptor.folderName).appendingPathComponent("weights.bin")
        }
        var legacyFileExists: Bool { FileManager.default.fileExists(atPath: legacyFile.path) }
        var storeIsEmpty: Bool {
            let models = storeRoot.appendingPathComponent("v1.noindex/models")
            return ((try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? []).isEmpty
        }

        private static let bytes = Data("the pinned weights".utf8)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let remote = root.appendingPathComponent("remote", isDirectory: true)
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            try Self.bytes.write(to: remote.appendingPathComponent("weights.bin"))
            offlineDescriptorBase = remote
            descriptor = ModelDescriptor(
                id: "shared-fixture", tasks: [.liveTranscription], displayName: "Shared fixture",
                folderName: "shared-fixture-folder", resolveBase: remote, revision: "fixture",
                artifacts: [ModelArtifact(
                    path: "weights.bin",
                    sha256: SHA256.hash(data: Self.bytes).map { String(format: "%02x", $0) }.joined(),
                    sizeBytes: Self.bytes.count)],
                minimumRAMGB: 0, license: "fixture")
        }

        /// `offline` removes the download source, so any fetch fails the test.
        func store(_ consumer: ModelStore.Consumer, legacy: Bool = false, offline: Bool = false) -> ModelStore {
            if offline { try? FileManager.default.removeItem(at: offlineDescriptorBase) }
            return ModelStore(rootDirectory: storeRoot, consumer: consumer, legacyRoot: legacy ? legacyRoot : nil)
        }

        func writeLegacy(corrupting: Bool = false) throws {
            try FileManager.default.createDirectory(
                at: legacyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (corrupting ? Data("damaged".utf8) : Self.bytes).write(to: legacyFile)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
