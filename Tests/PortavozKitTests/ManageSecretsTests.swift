import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class ManageSecretsTests: XCTestCase {
    func testRoundTripAndDeleteUseInjectedStorage() async throws {
        let storage = TestSecretStorage()
        let secrets = ManageSecrets(storage: storage)
        let identifier = SecretIdentifier(rawValue: "test.secret")

        let initiallyStored = try await secrets.contains(identifier)
        XCTAssertFalse(initiallyStored)
        try await secrets.set("first", for: identifier)
        let first = try await secrets.value(for: identifier)
        XCTAssertEqual(first, "first")

        try await secrets.set("replacement", for: identifier)
        let replacement = try await secrets.value(for: identifier)
        XCTAssertEqual(replacement, "replacement")

        try await secrets.delete(identifier)
        let deleted = try await secrets.value(for: identifier)
        XCTAssertNil(deleted)
    }
}
