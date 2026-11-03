import Foundation
import Testing

@testable import portavoz_app

@MainActor
struct CallEndedNotifierTests {
    @Test
    func aQuestionWithdrawnDuringAuthorizationIsNeverPublished() async {
        let center = HeldCenter(holdAuthorization: true)
        let notifier = CallEndedNotifier(center: center)
        let publication = notifier.post(title: "t", body: "b", sessionID: UUID())
        for await _ in center.authorizationStarted.stream { break }
        notifier.withdraw()
        center.authorization.continuation.yield()
        await publication.value
        #expect(center.added.isEmpty)
    }

    @Test
    func aQuestionWithdrawnWhilePublishingRemovesOnlyItself() async throws {
        let center = HeldCenter(holdAdd: true)
        let notifier = CallEndedNotifier(center: center)
        let session = UUID()
        let stale = notifier.post(title: "t", body: "b", sessionID: session)
        for await _ in center.addStarted.stream { break }
        let staleID = try #require(center.added.first)
        notifier.withdraw()
        center.holdAdd = false
        notifier.post(title: "t", body: "b", sessionID: session)
        center.addRelease.continuation.yield()
        await stale.value
        #expect(center.removed.filter { $0 == staleID }.count == 2)
        #expect(!notifier.accepts(identifier: staleID, sessionID: session))
        let fresh = try #require(center.added.last)
        #expect(!center.removed.contains(fresh))
        #expect(notifier.accepts(identifier: fresh, sessionID: session))
    }

    @Test
    func onlyTheCurrentQuestionOfItsRecordingIsAccepted() async {
        let center = HeldCenter()
        let notifier = CallEndedNotifier(center: center)
        let first = UUID(), second = UUID()
        await notifier.post(title: "t", body: "b", sessionID: first).value
        await notifier.post(title: "t", body: "b", sessionID: second).value
        let old = center.added[0], current = center.added[1]
        #expect(!notifier.accepts(identifier: old, sessionID: first))
        #expect(!notifier.accepts(identifier: current, sessionID: first))
        #expect(notifier.accepts(identifier: current, sessionID: second))
        notifier.withdraw()
        #expect(!notifier.accepts(identifier: current, sessionID: second))
    }

    @Test
    func launchRemovesQuestionsLeftByAnEarlierProcess() async {
        let center = HeldCenter(holdDelivered: true)
        let notifier = CallEndedNotifier(center: center)
        let cleanup = Task { await notifier.removeOrphans() }
        for await _ in center.deliveredStarted.stream { break }
        await notifier.post(title: "t", body: "b", sessionID: UUID()).value
        let current = center.added[0]
        center.delivered = ["portavoz.call-ended", "portavoz.call-ended.old", current]
        center.deliveredRelease.continuation.yield()
        await cleanup.value
        #expect(center.removed == ["portavoz.call-ended", "portavoz.call-ended.old"])
    }
}

@MainActor
private final class HeldCenter: CallEndedNotificationCenter {
    let authorization = AsyncStream<Void>.makeStream()
    let authorizationStarted = AsyncStream<Void>.makeStream()
    let deliveredStarted = AsyncStream<Void>.makeStream()
    let deliveredRelease = AsyncStream<Void>.makeStream()
    let addStarted = AsyncStream<Void>.makeStream()
    let addRelease = AsyncStream<Void>.makeStream()
    var holdAuthorization: Bool
    var holdAdd: Bool
    let holdDelivered: Bool
    var added: [String] = []
    var removed: [String] = []
    var delivered: [String] = []

    init(holdAuthorization: Bool = false, holdAdd: Bool = false, holdDelivered: Bool = false) {
        self.holdAuthorization = holdAuthorization
        self.holdAdd = holdAdd
        self.holdDelivered = holdDelivered
    }

    func canPost() async -> Bool {
        guard holdAuthorization else { return true }
        authorizationStarted.continuation.yield()
        for await _ in authorization.stream { break }
        return true
    }

    func add(identifier: String, title: String, body: String, sessionID: UUID) async {
        added.append(identifier)
        guard holdAdd else { return }
        addStarted.continuation.yield()
        for await _ in addRelease.stream { break }
    }

    func remove(identifiers: [String]) {
        removed += identifiers
    }

    func deliveredIdentifiers() async -> [String] {
        if holdDelivered {
            deliveredStarted.continuation.yield()
            for await _ in deliveredRelease.stream { break }
        }
        return delivered
    }
}
