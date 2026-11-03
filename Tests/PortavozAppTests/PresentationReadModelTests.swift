import ApplicationKit
import XCTest

@testable import portavoz_app

@MainActor
final class PresentationReadModelTests: XCTestCase {
    func testFirstRunModelResolvesOnceAndRemembersExistingLibrary() async {
        let client = FirstRunModelClientFake(resolution: .init(
            shouldPresent: false,
            shouldMarkCompleted: true))
        let model = FirstRunModel(client: client)
        let firstHost = UUID()
        let secondHost = UUID()

        await model.resolve(in: firstHost)
        await model.resolve(in: secondHost)

        XCTAssertTrue(model.hasResolved)
        XCTAssertFalse(model.isPresented)
        XCTAssertEqual(client.resolveCalls, 1)
        XCTAssertEqual(client.markCalls, 1)
        XCTAssertFalse(model.isPresented(in: firstHost))
        XCTAssertFalse(model.isPresented(in: secondHost))
    }

    func testFirstRunFinishPersistsAndDismisses() async {
        let client = FirstRunModelClientFake(resolution: .init(
            shouldPresent: true,
            shouldMarkCompleted: false))
        let model = FirstRunModel(client: client)
        let hostID = UUID()
        await model.resolve(in: hostID)

        model.finish()

        XCTAssertTrue(model.hasResolved)
        XCTAssertFalse(model.isPresented)
        XCTAssertFalse(model.isPresented(in: hostID))
        XCTAssertEqual(client.markCalls, 1)
    }

    func testFirstRunPresentationBelongsToOnlyOneRestoredWindow() async {
        let client = FirstRunModelClientFake(resolution: .init(
            shouldPresent: true,
            shouldMarkCompleted: false))
        let model = FirstRunModel(client: client)
        let firstHost = UUID()
        let secondHost = UUID()

        await model.resolve(in: firstHost)
        await model.resolve(in: secondHost)

        XCTAssertTrue(model.isPresented(in: firstHost))
        XCTAssertFalse(model.isPresented(in: secondHost))
        XCTAssertEqual(client.resolveCalls, 1)
    }

    func testFirstRunPresentationMovesWhenItsWindowCloses() async {
        let client = FirstRunModelClientFake(resolution: .init(
            shouldPresent: true,
            shouldMarkCompleted: false))
        let model = FirstRunModel(client: client)
        let firstHost = UUID()
        let secondHost = UUID()

        model.register(hostID: firstHost)
        model.register(hostID: secondHost)
        await model.resolve(in: firstHost)
        model.unregister(hostID: firstHost)

        XCTAssertFalse(model.isPresented(in: firstHost))
        XCTAssertTrue(model.isPresented(in: secondHost))
        XCTAssertEqual(client.resolveCalls, 1)
    }

    func testLedgerModelPublishesExactAndPartialSnapshots() async {
        let exact = LocalDataLedgerSnapshot(
            audioBytes: 512,
            meetingCount: 2,
            voiceCount: 1)
        let client = LocalDataLedgerModelClientFake(snapshot: exact)
        let model = LocalDataLedgerModel(client: client)

        await model.load()

        XCTAssertEqual(model.phase, .loaded(exact))
        XCTAssertEqual(client.calls, 1)
    }

    func testLedgerCancellationRestoresPreviousSnapshot() async {
        let exact = LocalDataLedgerSnapshot(
            audioBytes: 512,
            meetingCount: 2,
            voiceCount: 1)
        let client = LocalDataLedgerModelClientFake(snapshot: exact)
        let model = LocalDataLedgerModel(client: client)
        await model.load()
        client.error = CancellationError()

        await model.load()

        XCTAssertEqual(model.phase, .loaded(exact))
        XCTAssertEqual(client.calls, 2)
    }
}

@MainActor
private final class FirstRunModelClientFake: FirstRunModelClient {
    let resolution: ResolveFirstRunExperience.Resolution
    var resolveCalls = 0
    var markCalls = 0

    init(resolution: ResolveFirstRunExperience.Resolution) {
        self.resolution = resolution
    }

    func resolveFirstRun() -> ResolveFirstRunExperience.Resolution {
        resolveCalls += 1
        return resolution
    }

    func markFirstRunCompleted() {
        markCalls += 1
    }
}

@MainActor
private final class LocalDataLedgerModelClientFake: LocalDataLedgerModelClient {
    let snapshot: LocalDataLedgerSnapshot
    var error: Error?
    var calls = 0

    init(snapshot: LocalDataLedgerSnapshot) {
        self.snapshot = snapshot
    }

    func loadLocalDataLedger() throws -> LocalDataLedgerSnapshot {
        calls += 1
        if let error { throw error }
        return snapshot
    }
}
