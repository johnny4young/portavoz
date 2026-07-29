@testable import PlatformKit
import XCTest

final class MicrophonePermissionClientTests: XCTestCase {
    func testAuthorizedStateDoesNotPromptAgain() async {
        let requests = PermissionRequestRecorder(result: false)
        let client = MicrophonePermissionClient(
            state: { .authorized },
            request: { await requests.request() })

        let authorized = await client.authorizeIfNeeded()
        let requestCount = await requests.count

        XCTAssertTrue(authorized)
        XCTAssertEqual(requestCount, 0)
    }

    func testUndeterminedStateReturnsGrantedPromptResult() async {
        let requests = PermissionRequestRecorder(result: true)
        let client = MicrophonePermissionClient(
            state: { .notDetermined },
            request: { await requests.request() })

        let authorized = await client.authorizeIfNeeded()
        let requestCount = await requests.count

        XCTAssertTrue(authorized)
        XCTAssertEqual(requestCount, 1)
    }

    func testUndeterminedStateReturnsRejectedPromptResult() async {
        let requests = PermissionRequestRecorder(result: false)
        let client = MicrophonePermissionClient(
            state: { .notDetermined },
            request: { await requests.request() })

        let authorized = await client.authorizeIfNeeded()
        let requestCount = await requests.count

        XCTAssertFalse(authorized)
        XCTAssertEqual(requestCount, 1)
    }

    func testDeniedAndRestrictedStatesFailWithoutPrompting() async {
        for state in [
            MicrophonePermissionState.denied,
            .restricted,
        ] {
            let requests = PermissionRequestRecorder(result: true)
            let client = MicrophonePermissionClient(
                state: { state },
                request: { await requests.request() })

            let authorized = await client.authorizeIfNeeded()
            let requestCount = await requests.count

            XCTAssertFalse(authorized)
            XCTAssertEqual(requestCount, 0)
        }
    }
}

private actor PermissionRequestRecorder {
    private(set) var count = 0
    private let result: Bool

    init(result: Bool) {
        self.result = result
    }

    func request() -> Bool {
        count += 1
        return result
    }
}
