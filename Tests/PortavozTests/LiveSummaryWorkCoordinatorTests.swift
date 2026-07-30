import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class LiveSummaryWorkCoordinatorTests: XCTestCase {
    func testBurstSignalsCollapseIntoOneDelayedCycle() async {
        let sleep = ControlledLiveSummarySleep()
        let operation = ControlledLiveSummaryOperation()
        let coordinator = makeCoordinator(sleep: sleep, operation: operation)

        for _ in 0..<100 {
            coordinator.request()
        }
        await waitUntil { await sleep.callCount == 1 }
        await sleep.resumeNext()
        await waitUntil { await operation.startCount == 1 }
        await operation.finish(backlog: false)
        await waitUntil { !coordinator.isRunning }

        let sleepCount = await sleep.callCount
        let maximumConcurrentCount = await operation.maximumConcurrentCount
        XCTAssertEqual(sleepCount, 1)
        XCTAssertEqual(maximumConcurrentCount, 1)
        XCTAssertFalse(coordinator.hasPendingWork)
    }

    func testSignalsDuringActiveCycleRetainOnlyOneLaterCycle() async {
        let sleep = ControlledLiveSummarySleep()
        let operation = ControlledLiveSummaryOperation()
        let coordinator = makeCoordinator(sleep: sleep, operation: operation)

        coordinator.request()
        await waitUntil { await sleep.callCount == 1 }
        await sleep.resumeNext()
        await waitUntil { await operation.startCount == 1 }

        for _ in 0..<100 {
            coordinator.request()
        }
        await operation.finish(backlog: false)
        await waitUntil { await sleep.callCount == 2 }
        let firstStartCount = await operation.startCount
        XCTAssertEqual(firstStartCount, 1)

        await sleep.resumeNext()
        await waitUntil { await operation.startCount == 2 }
        await operation.finish(backlog: false)
        await waitUntil { !coordinator.isRunning }

        let sleepCount = await sleep.callCount
        let maximumConcurrentCount = await operation.maximumConcurrentCount
        XCTAssertEqual(sleepCount, 2)
        XCTAssertEqual(maximumConcurrentCount, 1)
    }

    func testRetainedBacklogSchedulesOneLaterCycleWithoutAnotherSignal() async {
        let sleep = ControlledLiveSummarySleep()
        let operation = ControlledLiveSummaryOperation()
        let coordinator = makeCoordinator(sleep: sleep, operation: operation)

        coordinator.request()
        await waitUntil { await sleep.callCount == 1 }
        await sleep.resumeNext()
        await waitUntil { await operation.startCount == 1 }
        await operation.finish(backlog: true)

        await waitUntil { await sleep.callCount == 2 }
        await sleep.resumeNext()
        await waitUntil { await operation.startCount == 2 }
        await operation.finish(backlog: false)
        await waitUntil { !coordinator.isRunning }

        let startCount = await operation.startCount
        XCTAssertEqual(startCount, 2)
    }

    func testCancellationDropsDelayedWorkAndFreshRequestUsesNewWorker() async {
        let sleep = ControlledLiveSummarySleep()
        let operation = ControlledLiveSummaryOperation()
        let coordinator = makeCoordinator(sleep: sleep, operation: operation)

        coordinator.request()
        await waitUntil { await sleep.callCount == 1 }
        coordinator.cancel()
        await waitUntil { !coordinator.isRunning }

        let cancelledStartCount = await operation.startCount
        XCTAssertEqual(cancelledStartCount, 0)
        XCTAssertFalse(coordinator.hasPendingWork)

        coordinator.request()
        await waitUntil { await sleep.callCount == 2 }
        await sleep.resumeNext()
        await waitUntil { await operation.startCount == 1 }
        await operation.finish(backlog: false)
        await waitUntil { !coordinator.isRunning }

        let maximumConcurrentCount = await operation.maximumConcurrentCount
        XCTAssertEqual(maximumConcurrentCount, 1)
    }

    private func makeCoordinator(
        sleep: ControlledLiveSummarySleep,
        operation: ControlledLiveSummaryOperation
    ) -> LiveSummaryWorkCoordinator {
        LiveSummaryWorkCoordinator(
            interval: .seconds(40),
            sleep: { try await sleep.wait($0) },
            operation: { await operation.run() })
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for live-summary coordinator state")
    }
}

final class LiveSummaryWindowPolicyTests: XCTestCase {
    func testSelectsOldestUnseenRowsWithinTheRowLimit() {
        let rows = segments(["zero", "one", "two", "three", "open"])
        let selected = LiveSummaryWindowPolicy.unsummarizedClosedRows(
            rows,
            summarizedIDs: [rows[0].id],
            maximumRows: 2,
            maximumCharacters: 1_000)

        XCTAssertEqual(selected.map(\.id), [rows[1].id, rows[2].id])
        XCTAssertTrue(LiveSummaryWindowPolicy.hasUnsummarizedClosedRows(
            rows,
            summarizedIDs: Set(selected.map(\.id)).union([rows[0].id])))
    }

    func testCharacterBudgetStopsBeforeOverflowWithoutSkippingTheHead() {
        let rows = segments(["abc", "de", "tail", "open"])
        let selected = LiveSummaryWindowPolicy.unsummarizedClosedRows(
            rows,
            summarizedIDs: [],
            maximumRows: 10,
            maximumCharacters: 4)

        XCTAssertEqual(selected.map(\.id), [rows[0].id])
    }

    func testOversizedOldestRowStillMakesProgressAlone() {
        let rows = segments([String(repeating: "x", count: 20), "later", "open"])
        let selected = LiveSummaryWindowPolicy.unsummarizedClosedRows(
            rows,
            summarizedIDs: [],
            maximumRows: 10,
            maximumCharacters: 5)

        XCTAssertEqual(selected.map(\.id), [rows[0].id])
    }

    private func segments(_ texts: [String]) -> [TranscriptSegment] {
        let meetingID = MeetingID()
        return texts.enumerated().map { index, text in
            TranscriptSegment(
                meetingID: meetingID,
                channel: .system,
                text: text,
                startTime: TimeInterval(index),
                endTime: TimeInterval(index + 1))
        }
    }
}

private actor ControlledLiveSummarySleep {
    private(set) var callCount = 0
    private var order: [UUID] = []
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait(_ duration: Duration) async throws {
        _ = duration
        let id = UUID()
        callCount += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                order.append(id)
                continuations[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func resumeNext() {
        guard let id = order.first else { return }
        order.removeFirst()
        continuations.removeValue(forKey: id)?.resume()
    }

    private func cancel(_ id: UUID) {
        order.removeAll { $0 == id }
        continuations.removeValue(forKey: id)?.resume(
            throwing: CancellationError())
    }
}

private actor ControlledLiveSummaryOperation {
    private(set) var startCount = 0
    private(set) var maximumConcurrentCount = 0
    private var activeCount = 0
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    func run() async -> Bool {
        startCount += 1
        activeCount += 1
        maximumConcurrentCount = max(maximumConcurrentCount, activeCount)
        let backlog = await withCheckedContinuation {
            continuations.append($0)
        }
        activeCount -= 1
        return backlog
    }

    func finish(backlog: Bool) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: backlog)
    }
}
