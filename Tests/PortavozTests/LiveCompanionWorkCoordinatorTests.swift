import IntelligenceKit
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class LiveCompanionWorkCoordinatorTests: XCTestCase {
    func testKeepsOneActiveGenerationAndOnlyTheLatestPendingCandidate() async {
        let generator = ControlledCompanionGenerator()
        let received = CompanionResultSink()
        let coordinator = LiveCompanionWorkCoordinator(
            generator: { await generator.generate($0) },
            receiver: { request, _ in received.append(request.candidate) })

        coordinator.submit(request("first"))
        await waitUntil { await generator.started == ["first"] }

        coordinator.submit(request("replaced"))
        coordinator.submit(request("latest"))
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertTrue(coordinator.hasPendingWork)

        await generator.finish("first")
        await waitUntil { await generator.started == ["first", "latest"] }
        await generator.finish("latest")
        await waitUntil { !coordinator.isRunning }

        XCTAssertEqual(received.candidates, ["first", "latest"])
        XCTAssertFalse(coordinator.hasPendingWork)
    }

    func testCancellationDropsPendingAndFencesAnUncooperativeActiveResult() async {
        let generator = ControlledCompanionGenerator()
        let received = CompanionResultSink()
        let coordinator = LiveCompanionWorkCoordinator(
            generator: { await generator.generate($0) },
            receiver: { request, _ in received.append(request.candidate) })

        coordinator.submit(request("active"))
        await waitUntil { await generator.started == ["active"] }
        coordinator.submit(request("discarded"))

        coordinator.cancel()
        XCTAssertFalse(coordinator.hasPendingWork)
        coordinator.submit(request("next-lifecycle"))

        // The controlled generator deliberately ignores task cancellation.
        // The fresh request must wait until that obsolete operation unwinds.
        await generator.finish("active")
        await waitUntil {
            await generator.started == ["active", "next-lifecycle"]
        }
        await generator.finish("next-lifecycle")
        await waitUntil { !coordinator.isRunning }

        XCTAssertEqual(received.candidates, ["next-lifecycle"])
    }

    func testDisablingApuntadorCancelsTheRecordingScopedCoordinator() async {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "companionEnabled")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "companionEnabled")
            } else {
                defaults.removeObject(forKey: "companionEnabled")
            }
        }

        let generator = ControlledCompanionGenerator()
        let received = CompanionResultSink()
        let coordinator = LiveCompanionWorkCoordinator(
            generator: { await generator.generate($0) },
            receiver: { request, _ in received.append(request.candidate) })
        let controller = RecordingController()
        controller.companionWorkCoordinator = coordinator
        controller.companionEnabled = true

        coordinator.submit(request("active"))
        await waitUntil { await generator.started == ["active"] }
        coordinator.submit(request("pending"))

        controller.companionEnabled = false
        XCTAssertFalse(coordinator.hasPendingWork)

        await generator.finish("active")
        await waitUntil { !coordinator.isRunning }
        XCTAssertEqual(received.candidates, [])
    }

    private func request(_ candidate: String) -> CompanionGenerationRequest {
        CompanionGenerationRequest(
            meetingID: MeetingID(),
            sourceTranscriptRevision: 0,
            sourceCorrectionRevision: .accepted,
            workflow: .liveRecording,
            candidate: candidate,
            questionSegmentIDs: [UUID()],
            recentTranscript: [],
            ownerName: nil,
            outputLanguage: "en",
            askedAt: 1)
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
        XCTFail("Timed out waiting for coordinator state")
    }
}

private actor ControlledCompanionGenerator {
    private(set) var started: [String] = []
    private var continuations: [
        String: CheckedContinuation<CompanionGenerationResult, Never>
    ] = [:]

    func generate(
        _ request: CompanionGenerationRequest
    ) async -> CompanionGenerationResult {
        started.append(request.candidate)
        return await withCheckedContinuation {
            continuations[request.candidate] = $0
        }
    }

    func finish(_ candidate: String) {
        continuations.removeValue(forKey: candidate)?.resume(returning: .noAttempt)
    }
}

@MainActor
private final class CompanionResultSink {
    private(set) var candidates: [String] = []

    func append(_ candidate: String) {
        candidates.append(candidate)
    }
}
