import CryptoKit
import Foundation
import ModelStoreKit
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ModelStoreLeaseTests {
    @Test func anotherStoreCannotRemoveTheFilesUntilTheLastLeaseReferenceEnds() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let directory = try await store.ensureAvailable(fixture.descriptor)
        var lease: ModelStore.ModelLease? = try await store.lease(fixture.descriptor)
        var secondReference = lease
        lease = nil

        #expect(secondReference?.directory == directory)
        #expect(secondReference?.isProtected == true)
        #expect(try await fixture.store().remove(fixture.descriptor) == .deferred)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        withExtendedLifetime(secondReference) {}

        secondReference = nil
        #expect(try await fixture.store().remove(fixture.descriptor) == .removed)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func bytesFromAnotherAppDoNotAuthorizeALease() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = fixture.store(identifier: "app.other.fixture")
        _ = try await other.ensureAvailable(fixture.descriptor)

        await #expect(throws: ModelStore.ModelStoreError.self) {
            try await fixture.store().lease(fixture.descriptor)
        }
        #expect(try await other.remove(fixture.descriptor) == .removed)
    }

    @Test func missingBytesFailLocallyWithoutInstallingOrLeavingALease() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()

        await #expect(throws: ModelStore.ModelStoreError.self) {
            try await store.lease(fixture.descriptor)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.storeRoot.path))

        _ = try await store.ensureAvailable(fixture.descriptor)
        #expect(try await store.remove(fixture.descriptor) == .removed)
        await #expect(throws: ModelStore.ModelStoreError.self) {
            try await store.lease(fixture.descriptor)
        }
        #expect(await store.verifiedInstallation(fixture.descriptor) == nil)
    }

    @Test func aCancelledBorrowDoesNotKeepTheFilesOnDisk() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        _ = try await store.ensureAvailable(fixture.descriptor)
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate.stream { break }
            return try await store.lease(fixture.descriptor)
        }
        task.cancel()
        gate.continuation.finish()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.remove(fixture.descriptor) == .removed)
    }

    struct Fixture {
        let root: URL
        let descriptor: ModelDescriptor
        var storeRoot: URL { root.appendingPathComponent("store", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let source = root.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let bytes = Data("synthetic leased weights".utf8)
            try bytes.write(to: source.appendingPathComponent("weights.bin"))
            descriptor = ModelDescriptor(
                id: "lease-fixture", tasks: [.liveTranscription], displayName: "Lease fixture",
                folderName: "fixture", resolveBase: source, revision: "fixture",
                artifacts: [ModelArtifact(
                    path: "weights.bin",
                    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                    sizeBytes: bytes.count)], minimumRAMGB: 0, license: "fixture")
        }

        func store(identifier: String = "app.portavoz.fixture") -> ModelStore {
            ModelStore(rootDirectory: storeRoot, consumer: .init(identifier: identifier, displayName: identifier))
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
