import Dispatch
import Foundation
import PortavozCore
import XCTest

@testable import DiarizationKit

private func waitForSemaphore(
    for semaphore: DispatchSemaphore,
    timeout: TimeInterval
) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

private final class BlockingSecretStorage: SecretStoring, @unchecked Sendable {
    private let base: any SecretStoring
    private let lock = NSLock()
    private let firstOperationEntered = DispatchSemaphore(value: 0)
    private let releaseFirstOperation = DispatchSemaphore(value: 0)
    private let laterOperationEntered = DispatchSemaphore(value: 0)
    private var isArmed = false
    private var operationCount = 0

    init(base: any SecretStoring) {
        self.base = base
    }

    func arm() {
        lock.withLock {
            isArmed = true
            operationCount = 0
        }
    }

    func waitForFirstOperation(timeout: TimeInterval) -> Bool {
        firstOperationEntered.wait(timeout: .now() + timeout) == .success
    }

    func waitForLaterOperation(timeout: TimeInterval) -> Bool {
        laterOperationEntered.wait(timeout: .now() + timeout) == .success
    }

    func releaseFirst() {
        releaseFirstOperation.signal()
    }

    func set(_ secret: String, for identifier: SecretIdentifier) throws {
        rendezvousIfArmed()
        try base.set(secret, for: identifier)
    }

    func value(for identifier: SecretIdentifier) throws -> String? {
        rendezvousIfArmed()
        return try base.value(for: identifier)
    }

    func delete(_ identifier: SecretIdentifier) throws {
        rendezvousIfArmed()
        try base.delete(identifier)
    }

    private func rendezvousIfArmed() {
        let ordinal = lock.withLock { () -> Int? in
            guard isArmed else { return nil }
            operationCount += 1
            return operationCount
        }
        switch ordinal {
        case 1:
            firstOperationEntered.signal()
            releaseFirstOperation.wait()
        case .some:
            laterOperationEntered.signal()
        case nil:
            break
        }
    }
}

final class VoiceIdentityConcurrencyTests: XCTestCase {
    func testConcurrentSaveThenDeleteCannotStrandCiphertextWithoutItsKey() async throws {
        let fixture = makeFixture(prefix: "voice")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = VoiceprintStore(
            secrets: fixture.secrets,
            directory: fixture.directory,
            keyIdentifier: fixture.keyIdentifier)
        try store.save(Voiceprint(embedding: [1, 2, 3]))
        let gatedSecrets = BlockingSecretStorage(base: fixture.secrets)
        let savingStore = VoiceprintStore(
            secrets: gatedSecrets,
            directory: fixture.directory,
            keyIdentifier: fixture.keyIdentifier)
        let deletingStore = VoiceprintStore(
            secrets: gatedSecrets,
            directory: fixture.directory,
            keyIdentifier: fixture.keyIdentifier)
        gatedSecrets.arm()

        let save = Task.detached(priority: .utility) {
            try savingStore.save(Voiceprint(embedding: [4, 5, 6]))
        }
        guard gatedSecrets.waitForFirstOperation(timeout: 5) else {
            gatedSecrets.releaseFirst()
            _ = try? await save.value
            return XCTFail("save never reached the secret store")
        }
        let deleteStarted = DispatchSemaphore(value: 0)
        let delete = Task.detached(priority: .utility) {
            deleteStarted.signal()
            try deletingStore.delete()
        }
        guard waitForSemaphore(for: deleteStarted, timeout: 5) else {
            gatedSecrets.releaseFirst()
            _ = try? await save.value
            delete.cancel()
            return XCTFail("delete task never started")
        }

        XCTAssertFalse(
            gatedSecrets.waitForLaterOperation(timeout: 1),
            "delete must stay behind the save's complete ciphertext/key transaction")
        gatedSecrets.releaseFirst()
        try await save.value
        try await delete.value

        XCTAssertFalse(store.exists)
        XCTAssertNil(try fixture.secrets.value(for: fixture.keyIdentifier))
        XCTAssertNil(try store.load())
    }

    func testConcurrentRemembersAcrossStoreValuesPreserveBothUpdates() async throws {
        let fixture = makeFixture(prefix: "gallery")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gallery = VoiceGallery(
            secrets: fixture.secrets,
            directory: fixture.directory,
            keyIdentifier: fixture.keyIdentifier)
        try gallery.remember(RememberedVoice(name: "Ada", embedding: [1, 0, 0]))
        let gatedSecrets = BlockingSecretStorage(base: fixture.secrets)
        let firstGallery = VoiceGallery(
            secrets: gatedSecrets,
            directory: fixture.directory,
            keyIdentifier: fixture.keyIdentifier)
        let secondGallery = VoiceGallery(
            secrets: gatedSecrets,
            directory: fixture.directory,
            keyIdentifier: fixture.keyIdentifier)
        gatedSecrets.arm()

        let first = Task.detached(priority: .utility) {
            try firstGallery.remember(
                RememberedVoice(name: "Marta", embedding: [0, 1, 0]))
        }
        guard gatedSecrets.waitForFirstOperation(timeout: 5) else {
            gatedSecrets.releaseFirst()
            _ = try? await first.value
            return XCTFail("first remember never reached the secret store")
        }
        let secondStarted = DispatchSemaphore(value: 0)
        let second = Task.detached(priority: .utility) {
            secondStarted.signal()
            try secondGallery.remember(
                RememberedVoice(name: "Ilarion", embedding: [0, 0, 1]))
        }
        guard waitForSemaphore(for: secondStarted, timeout: 5) else {
            gatedSecrets.releaseFirst()
            _ = try? await first.value
            second.cancel()
            return XCTFail("second remember task never started")
        }

        XCTAssertFalse(
            gatedSecrets.waitForLaterOperation(timeout: 1),
            "a second store value must not read the gallery mid-transaction")
        gatedSecrets.releaseFirst()
        try await first.value
        try await second.value

        XCTAssertEqual(
            Set(try gallery.voices().map(\.name)),
            Set(["Ada", "Marta", "Ilarion"]))
    }

    private func makeFixture(
        prefix: String
    ) -> (directory: URL, keyIdentifier: SecretIdentifier, secrets: TestSecretStorage) {
        let token = UUID().uuidString
        return (
            FileManager.default.temporaryDirectory
                .appendingPathComponent("portavoz-\(prefix)-\(token)"),
            SecretIdentifier(rawValue: "app.portavoz.tests.\(prefix).\(token)"),
            TestSecretStorage())
    }
}
