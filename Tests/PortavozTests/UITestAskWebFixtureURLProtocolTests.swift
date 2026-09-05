import Foundation
import XCTest
@testable import portavoz_app

final class UITestAskWebFixtureURLProtocolTests: XCTestCase {
    func testCanonicalPayloadLoadsEveryBoundedBehavior() throws {
        let fixture = try XCTUnwrap(
            UITestAskWebFixtureURLProtocol.fixture(
                environment: try canonicalEnvironment()))

        XCTAssertEqual(fixture.routes.count, 14)
        XCTAssertEqual(
            fixture.routes["/source/fresh-en"]?.behavior,
            .slow)
        XCTAssertEqual(
            fixture.routes["/source/fresh-en"]?.delayMilliseconds,
            500)
        XCTAssertEqual(
            fixture.routes["/source/fresh-en"]?.status,
            200)
        XCTAssertEqual(
            fixture.routes["/redirect/fresh-en"]?.location,
            "/source/fresh-en")
        XCTAssertEqual(
            fixture.routes["/error/provider-down"]?.status,
            503)
        XCTAssertEqual(
            fixture.routes["/partial/fresh-en"]?.behavior,
            .partial)
        XCTAssertEqual(
            fixture.routes["/transport/disconnect"]?.behavior,
            .disconnect)
        XCTAssertEqual(
            fixture.routes["/hostile/prompt-injection-es"]?.trust,
            "untrusted")
    }

    func testInvalidOrOversizedPayloadFailsClosed() throws {
        var changed = try canonicalData()
        changed.append(0x20)

        XCTAssertNil(UITestAskWebFixtureURLProtocol.fixture(environment: [:]))
        XCTAssertNil(UITestAskWebFixtureURLProtocol.fixture(environment: [
            UITestAskWebFixtureURLProtocol.environmentKey: "not-base64",
        ]))
        XCTAssertNil(UITestAskWebFixtureURLProtocol.fixture(environment: [
            UITestAskWebFixtureURLProtocol.environmentKey:
                changed.base64EncodedString(),
        ]))
        XCTAssertNil(UITestAskWebFixtureURLProtocol.fixture(environment: [
            UITestAskWebFixtureURLProtocol.environmentKey:
                String(repeating: "A", count: 12_001),
        ]))
    }

    func testSessionInstallsProtocolOnlyForAValidatedPayload() throws {
        let valid = URLSessionConfiguration.ephemeral
        XCTAssertTrue(UITestAskWebFixtureURLProtocol.install(
            into: valid,
            environment: try canonicalEnvironment()))
        XCTAssertTrue(valid.protocolClasses?.contains {
            $0 == UITestAskWebFixtureURLProtocol.self
        } == true)

        let invalid = URLSessionConfiguration.ephemeral
        XCTAssertFalse(UITestAskWebFixtureURLProtocol.install(
            into: invalid,
            environment: [:]))
        XCTAssertFalse(invalid.protocolClasses?.contains {
            $0 == UITestAskWebFixtureURLProtocol.self
        } == true)
    }

    func testProtocolAcceptsOnlyTheFixedLoopbackGetOrigin() {
        var valid = URLRequest(url: UITestAskWebFixtureURLProtocol.fixtureBaseURL
            .appendingPathComponent("source/fresh-en"))
        valid.httpMethod = "GET"
        XCTAssertTrue(UITestAskWebFixtureURLProtocol.canInit(with: valid))

        var post = valid
        post.httpMethod = "POST"
        XCTAssertFalse(UITestAskWebFixtureURLProtocol.canInit(with: post))
        XCTAssertFalse(UITestAskWebFixtureURLProtocol.canInit(with: URLRequest(
            url: URL(string: "http://127.0.0.1:54322/source/fresh-en")!)))
        XCTAssertFalse(UITestAskWebFixtureURLProtocol.canInit(with: URLRequest(
            url: URL(string: "https://127.0.0.1:54321/source/fresh-en")!)))
        XCTAssertFalse(UITestAskWebFixtureURLProtocol.canInit(with: URLRequest(
            url: URL(string: "http://127.0.0.1:54321/source/fresh-en?q=1")!)))
        XCTAssertFalse(UITestAskWebFixtureURLProtocol.canInit(with: URLRequest(
            url: URL(string: "http://127.0.0.1:54321/%73ource/fresh-en")!)))
    }

    private func canonicalEnvironment() throws -> [String: String] {
        [
            UITestAskWebFixtureURLProtocol.environmentKey:
                try canonicalData().base64EncodedString(),
        ]
    }

    private func canonicalData() throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent(
            "Fixtures/ApuntadorWeb/public-local-v1.json"))
    }
}
