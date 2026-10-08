import Foundation
import PortavozCore
import Security
import XCTest

@testable import PlatformKit

final class KeychainSecretReplacementTests: XCTestCase {
    private let identifier = SecretIdentifier(rawValue: "app.portavoz.tests.injected")

    /// All Security state is a locked process-local fixture, never the host Keychain.
    private final class SecurityFixture: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        private var accessibility: String?
        private var updateStatuses: [OSStatus]
        private var addStatus: OSStatus
        private var contender: Data?
        private var operations: [String] = []
        private var replacementKeys: [String] = []
        private var updateQueryKeys: [String] = []
        private var copyQueryKeys: [String] = []

        init(
            data: Data? = nil, accessibility: String? = nil,
            updateStatuses: [OSStatus] = [], addStatus: OSStatus = errSecSuccess,
            contender: Data? = nil
        ) {
            self.data = data
            self.accessibility = accessibility
            self.updateStatuses = updateStatuses
            self.addStatus = addStatus
            self.contender = contender
        }

        var client: KeychainSecretStore.SecurityClient {
            .init(
                update: { self.update($0, attributes: $1) },
                add: { self.add($0) },
                copyMatching: { self.read($0) },
                delete: { _ in self.delete() })
        }

        func snapshot() -> (data: Data?, accessibility: String?, operations: [String], keys: [String]) {
            lock.withLock { (data, accessibility, operations, replacementKeys) }
        }

        /// Keys of the last update query; SecItemUpdate rejects return/limit keys.
        func lastUpdateQueryKeys() -> [String] {
            lock.withLock { updateQueryKeys }
        }

        /// Keys of the last read query; reads alone carry return/limit keys.
        func lastCopyQueryKeys() -> [String] {
            lock.withLock { copyQueryKeys }
        }

        private func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
            lock.withLock {
                operations.append("update")
                updateQueryKeys = (query as NSDictionary).allKeys.compactMap { $0 as? String }.sorted()
                let values = attributes as NSDictionary
                replacementKeys = values.allKeys.compactMap { $0 as? String }.sorted()
                if !updateStatuses.isEmpty {
                    let status = updateStatuses.removeFirst()
                    if status != errSecSuccess { return status }
                }
                guard data != nil else { return errSecItemNotFound }
                data = values[kSecValueData as String] as? Data
                return errSecSuccess
            }
        }

        private func add(_ query: CFDictionary) -> OSStatus {
            lock.withLock {
                operations.append("add")
                if let contender {
                    data = contender
                    accessibility = "contender-accessibility"
                    self.contender = nil
                    return errSecDuplicateItem
                }
                guard addStatus == errSecSuccess else { return addStatus }
                guard data == nil else { return errSecDuplicateItem }
                let values = query as NSDictionary
                data = values[kSecValueData as String] as? Data
                accessibility = values[kSecAttrAccessible as String] as? String
                return errSecSuccess
            }
        }

        private func read(_ query: CFDictionary) -> (status: OSStatus, data: Data?) {
            lock.withLock {
                copyQueryKeys = (query as NSDictionary).allKeys.compactMap { $0 as? String }.sorted()
                return (data == nil ? errSecItemNotFound : errSecSuccess, data)
            }
        }

        private func delete() -> OSStatus {
            lock.withLock {
                operations.append("delete")
                data = nil
                return errSecSuccess
            }
        }
    }

    func testFailedUpdatePreservesValueAndAccessibilityWithoutAddOrDelete() throws {
        let original = Data("original-fixture".utf8)
        let fixture = SecurityFixture(
            data: original, accessibility: "original-accessibility",
            updateStatuses: [errSecAuthFailed])
        let store = KeychainSecretStore(security: fixture.client)

        XCTAssertThrowsError(try store.set("replacement-fixture", for: identifier)) { error in
            XCTAssertFalse(error.localizedDescription.contains("original-fixture"))
            XCTAssertFalse(error.localizedDescription.contains("replacement-fixture"))
        }
        let state = fixture.snapshot()
        XCTAssertEqual(state.data, original)
        XCTAssertEqual(state.accessibility, "original-accessibility")
        XCTAssertEqual(state.operations, ["update"])
        XCTAssertEqual(state.keys, [kSecValueData as String])
    }

    func testMissingItemCreatesWithDeviceOnlyAccessibility() throws {
        let fixture = SecurityFixture()
        let store = KeychainSecretStore(security: fixture.client)
        try store.set("created-fixture", for: identifier)

        let state = fixture.snapshot()
        XCTAssertEqual(state.data, Data("created-fixture".utf8))
        XCTAssertEqual(state.accessibility, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(state.operations, ["update", "add"])
    }

    func testSuccessfulReplacementChangesOnlyTheValue() throws {
        let fixture = SecurityFixture(
            data: Data("original-fixture".utf8), accessibility: "original-accessibility")
        let store = KeychainSecretStore(security: fixture.client)
        try store.set("replacement-fixture", for: identifier)

        let state = fixture.snapshot()
        XCTAssertEqual(state.data, Data("replacement-fixture".utf8))
        XCTAssertEqual(state.accessibility, "original-accessibility")
        XCTAssertEqual(state.operations, ["update"])
        XCTAssertEqual(state.keys, [kSecValueData as String])
        XCTAssertEqual(
            fixture.lastUpdateQueryKeys(),
            [kSecAttrAccount as String, kSecAttrService as String, kSecClass as String].sorted())
    }

    func testDuplicateFirstWriterConvergesWithOneUpdateRetry() throws {
        let fixture = SecurityFixture(contender: Data("contender-fixture".utf8))
        let store = KeychainSecretStore(security: fixture.client)
        try store.set("replacement-fixture", for: identifier)

        let state = fixture.snapshot()
        XCTAssertEqual(state.data, Data("replacement-fixture".utf8))
        XCTAssertEqual(state.accessibility, "contender-accessibility")
        XCTAssertEqual(state.operations, ["update", "add", "update"])
    }

    func testFailedDuplicateRetryPreservesTheContenderAndStops() throws {
        let original = Data("contender-fixture".utf8)
        let fixture = SecurityFixture(
            updateStatuses: [errSecItemNotFound, errSecAuthFailed], contender: original)
        let store = KeychainSecretStore(security: fixture.client)

        XCTAssertThrowsError(try store.set("replacement-fixture", for: identifier))
        let state = fixture.snapshot()
        XCTAssertEqual(state.data, original)
        XCTAssertEqual(state.accessibility, "contender-accessibility")
        XCTAssertEqual(state.operations, ["update", "add", "update"])
    }

    func testFailedCreationDoesNotDeleteAnything() throws {
        let fixture = SecurityFixture(addStatus: errSecNotAvailable)
        let store = KeychainSecretStore(security: fixture.client)

        XCTAssertThrowsError(try store.set("created-fixture", for: identifier))
        XCTAssertEqual(fixture.snapshot().operations, ["update", "add"])
        XCTAssertNil(fixture.snapshot().data)
    }

    func testMalformedStoredDataFailsClosedWithoutMutation() throws {
        let malformed = Data([0xFF, 0xFE])
        let fixture = SecurityFixture(data: malformed)
        let store = KeychainSecretStore(security: fixture.client)

        XCTAssertThrowsError(try store.value(for: identifier)) { error in
            guard let secretError = error as? KeychainSecretStore.SecretError,
                  case .invalidData = secretError else {
                return XCTFail("Expected a content-free invalid-data error")
            }
        }
        XCTAssertEqual(fixture.snapshot().data, malformed)
        XCTAssertTrue(fixture.snapshot().operations.isEmpty)
    }

    func testMissingItemReadsNilWithOneDataValueQuery() throws {
        let fixture = SecurityFixture()
        let store = KeychainSecretStore(security: fixture.client)

        XCTAssertNil(try store.value(for: identifier))
        XCTAssertEqual(
            fixture.lastCopyQueryKeys(),
            [kSecAttrAccount, kSecAttrService, kSecClass, kSecMatchLimit, kSecReturnData]
                .map { $0 as String }
                .sorted())
        XCTAssertTrue(fixture.snapshot().operations.isEmpty)
    }

    func testSuccessWithoutReturnedDataFailsClosed() throws {
        let client = KeychainSecretStore.SecurityClient(
            update: { _, _ in errSecParam },
            add: { _ in errSecParam },
            copyMatching: { _ in (errSecSuccess, nil) },
            delete: { _ in errSecParam })
        let store = KeychainSecretStore(security: client)

        XCTAssertThrowsError(try store.value(for: identifier)) { error in
            guard case .invalidData? = error as? KeychainSecretStore.SecretError else {
                return XCTFail("Expected a content-free invalid-data error")
            }
        }
    }
}
