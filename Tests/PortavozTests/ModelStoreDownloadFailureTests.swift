import Foundation
@testable import ModelStoreKit
import Testing

@testable import portavoz_app

struct ModelStoreDownloadFailureTests {
    @Test(arguments: ["posix-space.bin", "posix-quota.bin", "cocoa-space.bin", "nested-space.bin"])
    func diskSpaceDownloadFailuresRetainTheirTypedCauseAndPreviousArtifact(filename: String) async throws {
        let fixture = try makeFixture(filename: filename)
        defer { fixture.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: fixture.root) }
        do {
            try await fixture.store.ensureAvailable(fixture.descriptor)
            Issue.record("The synthetic download must fail")
        } catch let error as ModelStore.ModelStoreError {
            guard case .outOfSpace(let path) = error else {
                Issue.record("A full disk must be reported as out of space, not \(error)")
                return
            }
            #expect(path == filename)
        } catch {
            Issue.record("Unexpected transfer error: \(type(of: error))")
        }
        #expect(try Data(contentsOf: fixture.artifact) == fixture.previousBytes)
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: fixture.artifact.deletingLastPathComponent().path)
        #expect(contents == [filename], "A failed transfer must not publish or stage any artifact")
    }

    @MainActor
    @Test(arguments: ["posix-space.bin", "posix-quota.bin", "cocoa-space.bin", "nested-space.bin"])
    func onboardingDisplaysStorageRecoveryForActualModelStoreDownloadFailure(filename: String) async throws {
        let fixture = try makeFixture(filename: filename)
        defer { fixture.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let preparation = OnboardingModelPreparation()
        await preparation.prepare { _ = try await fixture.store.ensureAvailable(fixture.descriptor) }
        #expect(preparation.phase == .failed(.storage))
        #expect(try Data(contentsOf: fixture.artifact) == fixture.previousBytes)
    }

    @Test(arguments: ["network.bin", "cancelled.bin", "ordinary-file-io.bin"])
    func otherTransferFailuresKeepTheExistingDownloadFailureContract(filename: String) async throws {
        let fixture = try makeFixture(filename: filename)
        defer { fixture.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: fixture.root) }
        do {
            try await fixture.store.ensureAvailable(fixture.descriptor)
            Issue.record("The synthetic download must fail")
        } catch let error as ModelStore.ModelStoreError {
            guard case .downloadFailed(let path, let underlying) = error else {
                Issue.record("Non-storage transfer failures must retain their existing wrapper")
                return
            }
            #expect(path == filename)
            #expect(underlying.isEmpty == false)
        } catch {
            Issue.record("Unexpected transfer error: \(type(of: error))")
        }
        #expect(try Data(contentsOf: fixture.artifact) == fixture.previousBytes)
    }

    @Test func localWritesReportAFullDiskAndPassOtherErrorsThrough() throws {
        do {
            try ModelStore.storing("Encoder.mlmodelc/weights/weight.bin") {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                    NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                ])
            }
            Issue.record("A full disk must be thrown")
        } catch let error as ModelStore.ModelStoreError {
            guard case .outOfSpace(let path) = error else {
                Issue.record("A full disk must be reported as out of space, not \(error)")
                return
            }
            #expect(path == "Encoder.mlmodelc/weights/weight.bin")
            #expect(ModelStore.isOutOfSpace(error as NSError), "the typed case still reads as out of space")
        }
        do {
            try ModelStore.storing("vocab.json") { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
            Issue.record("A permission error must be thrown")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain && error.code == Int(EACCES), "only a full disk is rewrapped")
        }
    }

    private struct Fixture {
        let store: ModelStore
        let session: URLSession
        let descriptor: ModelDescriptor
        let root: URL
        let artifact: URL
        let previousBytes: Data
    }

    private func makeFixture(filename: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolveBase = try #require(URL(string: "https://model-store-download-failure.invalid"))
        let descriptor = ModelDescriptor(
            id: "download-failure-fixture", tasks: [.liveTranscription], displayName: "Download failure fixture",
            folderName: "fixture", resolveBase: resolveBase,
            revision: "fixture", artifacts: [
                ModelArtifact(path: filename, sha256: String(repeating: "0", count: 64), sizeBytes: 1)
            ],
            minimumRAMGB: 0, license: "fixture")
        let artifact = root.appendingPathComponent(descriptor.folderName).appendingPathComponent(filename)
        let previousBytes = Data("Existing corrupt artifact must survive a failed repair".utf8)
        do {
            try FileManager.default.createDirectory(
                at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
            try previousBytes.write(to: artifact)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelStoreDownloadFailureProtocol.self]
        let session = URLSession(configuration: configuration)
        return Fixture(store: ModelStore(rootDirectory: root, session: session), session: session,
                       descriptor: descriptor, root: root, artifact: artifact, previousBytes: previousBytes)
    }
}

/// Every request fails in-process before any network or model bytes are read.
/// This URLProtocol subclass adds no mutable state to the system-owned base.
private final class ModelStoreDownloadFailureProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let cause: NSError
        switch request.url?.lastPathComponent {
        case "posix-space.bin":
            cause = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        case "posix-quota.bin":
            cause = NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))
        case "cocoa-space.bin":
            cause = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        case "nested-space.bin":
            cause = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            ])
        case "network.bin":
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        case "cancelled.bin":
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        default:
            cause = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        client?.urlProtocol(self, didFailWithError: NSError(
            domain: NSURLErrorDomain, code: URLError.cannotWriteToFile.rawValue,
            userInfo: [NSUnderlyingErrorKey: cause]))
    }
}
