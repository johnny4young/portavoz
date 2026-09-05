import XCTest

@testable import portavoz_app

final class LiveTranslationWakeHubTests: XCTestCase {
    func testBurstWakeIsBroadcastToEveryBoundedSubscriber() async {
        let hub = LiveTranslationWakeHub()
        let first = hub.subscribe()
        let second = hub.subscribe()
        var firstIterator = first.stream.makeAsyncIterator()
        var secondIterator = second.stream.makeAsyncIterator()

        for _ in 0..<100 {
            hub.signal()
        }

        let firstWake: Void? = await firstIterator.next()
        let secondWake: Void? = await secondIterator.next()
        XCTAssertNotNil(firstWake)
        XCTAssertNotNil(secondWake)
        XCTAssertEqual(hub.subscriberCount, 2)

        first.cancel()
        second.cancel()
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testCancellationFinishesSubscriptionAndRejectsLaterSignals() async {
        let hub = LiveTranslationWakeHub()
        let subscription = hub.subscribe()
        var iterator = subscription.stream.makeAsyncIterator()

        subscription.cancel()
        hub.signal()

        let wake: Void? = await iterator.next()
        XCTAssertNil(wake)
        XCTAssertEqual(hub.subscriberCount, 0)
    }
}

@MainActor
final class LiveTranslationWakeIntegrationTests: XCTestCase {
    func testDownloadConsentWakesTheCurrentTranslationLane() async {
        let controller = RecordingController()
        let subscription = controller.liveTranslationWakeHub.subscribe()
        var iterator = subscription.stream.makeAsyncIterator()

        controller.translationDownloadApproved = true

        let wake: Void? = await iterator.next()
        XCTAssertNotNil(wake)
        subscription.cancel()
    }
}
