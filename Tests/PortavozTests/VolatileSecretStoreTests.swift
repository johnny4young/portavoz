import PlatformKit
import PortavozCore
import XCTest

final class VolatileSecretStoreTests: XCTestCase {
    func testRoundTripAndDeleteStayInsideOneProcessStore() throws {
        let store = VolatileSecretStore()
        let identifier = SecretIdentifier(
            rawValue: "app.portavoz.test.volatile")

        XCTAssertNil(try store.value(for: identifier))
        try store.set("private", for: identifier)
        XCTAssertEqual(
            try store.value(for: identifier),
            "private")
        try store.delete(identifier)
        XCTAssertNil(try store.value(for: identifier))
    }

    func testInstancesNeverShareSecrets() throws {
        let identifier = SecretIdentifier(
            rawValue: "app.portavoz.test.isolated")
        let first = VolatileSecretStore()
        let second = VolatileSecretStore()

        try first.set("first", for: identifier)

        XCTAssertEqual(try first.value(for: identifier), "first")
        XCTAssertNil(try second.value(for: identifier))
    }
}
