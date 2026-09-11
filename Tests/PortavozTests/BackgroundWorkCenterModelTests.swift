import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class BackgroundWorkCenterModelTests: XCTestCase {
    func testRecoveryPublishesCountsAndClosedFailureWithoutContent() async {
        let model = BackgroundWorkCenterModel()
        let token = model.begin(.recovery, stage: .recoveringRecordings)
        let privateMessage = "meeting-title/private/path/secret transcript"
        let result = RecoverInterruptedMeetingsResult(
            recoveredLeaseCount: 2,
            reconciledMeetingCount: 3,
            preservedFailureCount: 1,
            deferredMeetingCount: 4,
            libraryInvalidationRequired: true,
            issues: [.init(
                stage: .failurePreservation(MeetingID()),
                message: privateMessage)])

        model.finishRecovery(token, result: result)

        let snapshot = model.snapshots[.recovery]
        XCTAssertEqual(snapshot?.phase, .failed)
        XCTAssertEqual(snapshot?.lastFailure, .recoveryPreservation)
        XCTAssertEqual(snapshot?.metrics.recoveredLeases, 2)
        XCTAssertEqual(snapshot?.metrics.reconciledRecordings, 3)
        XCTAssertEqual(snapshot?.metrics.preservedRecoveryFailures, 1)
        XCTAssertEqual(snapshot?.metrics.deferredRecordings, 4)
        XCTAssertFalse(String(reflecting: snapshot).contains(privateMessage))
    }

    func testLateProcessingEventCannotReplaceCurrentAttempt() async {
        let model = BackgroundWorkCenterModel()
        let stale = model.begin(
            .processing,
            stage: .processing(.transcription),
            attempt: 1)
        let current = model.begin(
            .processing,
            stage: .processing(.summary),
            attempt: 2)

        model.finishProcessingJob(
            stale,
            kind: .transcription,
            attempt: 1,
            outcome: .failed)
        model.finishProcessingJob(
            current,
            kind: .summary,
            attempt: 2,
            outcome: .succeeded)
        model.finishProcessingDrain(
            current,
            result: ProcessPostCaptureJobsResult(
                processedJobCount: 1,
                durableStateChanged: true,
                issues: []),
            retryAt: nil)

        let snapshot = model.snapshots[.processing]
        XCTAssertEqual(snapshot?.phase, .idle)
        XCTAssertEqual(snapshot?.attempt, 2)
        XCTAssertEqual(snapshot?.lastOutcome, .succeeded)
        XCTAssertEqual(snapshot?.metrics.processedJobs, 1)
        XCTAssertNil(snapshot?.lastFailure)
    }

    func testProcessingRetryAndSchedulingFailureRemainDistinct() async {
        let model = BackgroundWorkCenterModel()
        let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
        let retryToken = model.begin(
            .processing,
            stage: .processing(.diarization),
            attempt: 2)
        let result = ProcessPostCaptureJobsResult(
            processedJobCount: 1,
            durableStateChanged: true,
            issues: [])

        model.finishProcessingDrain(
            retryToken,
            result: result,
            retryAt: retryAt)
        XCTAssertEqual(
            model.snapshots[.processing]?.phase,
            .retryScheduled(retryAt))

        let failedToken = model.begin(
            .processing,
            stage: .processing(nil))
        model.finishProcessingDrain(
            failedToken,
            result: result,
            retryAt: nil,
            schedulingFailed: true)
        XCTAssertEqual(model.snapshots[.processing]?.phase, .failed)
        XCTAssertEqual(model.snapshots[.processing]?.lastFailure, .scheduling)
    }

    func testSemanticAndGraphKeepExactTerminalCountsAndCapturePause() async {
        let model = BackgroundWorkCenterModel()
        let semantic = model.begin(
            .semanticIndex,
            stage: .semanticIndexing)
        let semanticRun = SemanticCorpusMaintenanceRun(indexing: .init(
            invalidatedSegments: 2,
            embeddedSegments: 12,
            excludedSegments: 3,
            skippedSegments: 1,
            pausedByPolicy: true))
        model.observeSemantic(semantic, run: semanticRun)
        model.finishSemantic(semantic, run: semanticRun)

        let semanticSnapshot = model.snapshots[.semanticIndex]
        XCTAssertEqual(semanticSnapshot?.phase, .waitingForRecording)
        XCTAssertEqual(semanticSnapshot?.lastOutcome, .suspended)
        XCTAssertEqual(semanticSnapshot?.metrics.invalidatedSegments, 2)
        XCTAssertEqual(semanticSnapshot?.metrics.embeddedSegments, 12)
        XCTAssertEqual(semanticSnapshot?.metrics.excludedSegments, 3)
        XCTAssertEqual(semanticSnapshot?.metrics.skippedSegments, 1)

        let graph = model.begin(
            .memoryGraph,
            stage: .projectingMemoryGraph)
        let retryAt = Date(timeIntervalSince1970: 1_800_000_100)
        let graphRun = MeetingMemoryGraphMaintenanceRun(
            projection: .init(rebuiltScopes: 4, publishedEdges: 9),
            retryAt: retryAt)
        model.observeMemoryGraph(graph, run: graphRun)
        model.finishMemoryGraph(graph, run: graphRun)

        XCTAssertEqual(
            model.snapshots[.memoryGraph]?.phase,
            .retryScheduled(retryAt))
        XCTAssertEqual(model.snapshots[.memoryGraph]?.metrics.rebuiltGraphScopes, 4)
        XCTAssertEqual(model.snapshots[.memoryGraph]?.metrics.publishedGraphEdges, 9)
    }

    func testSpotlightPhasesRetainRetryAndTerminalFailure() async {
        let model = BackgroundWorkCenterModel()
        let retryAt = Date(timeIntervalSince1970: 1_800_000_200)

        model.receiveSpotlight(.scheduled)
        XCTAssertEqual(model.snapshots[.spotlight]?.stage, .spotlightScheduled)
        model.receiveSpotlight(.projecting)
        XCTAssertEqual(model.snapshots[.spotlight]?.stage, .spotlightProjecting)
        model.receiveSpotlight(.publishing)
        model.receiveSpotlight(.retrying(attempt: 1), retryAt: retryAt)
        XCTAssertEqual(
            model.snapshots[.spotlight]?.phase,
            .retryScheduled(retryAt))
        model.receiveSpotlight(.failed(attempts: 3))
        XCTAssertEqual(model.snapshots[.spotlight]?.phase, .failed)
        XCTAssertEqual(model.snapshots[.spotlight]?.attempt, 3)
    }

    func testFixtureRequiresBothDisposableFlagsAndActionsStayLocal() async {
        let model = BackgroundWorkCenterModel()
        model.installUITestFixtureIfRequested(
            arguments: ["-seed-background-work"])
        XCTAssertFalse(model.hasVisibleActivity)

        model.installUITestFixtureIfRequested(
            arguments: ["-use-temp-store", "-seed-background-work"],
            at: Date(timeIntervalSince1970: 1_800_000_300))
        XCTAssertTrue(model.hasVisibleActivity)
        XCTAssertTrue(model.needsAttention)
        XCTAssertEqual(model.snapshots[.semanticIndex]?.metrics.embeddedSegments, 12)
        XCTAssertTrue(model.resolveUITestActionIfNeeded(for: .memoryGraph))
        XCTAssertEqual(model.snapshots[.memoryGraph]?.phase, .idle)
    }

    func testProjectionHasNoOwnedTaskAndDeallocates() async {
        weak var weakModel: BackgroundWorkCenterModel?
        autoreleasepool {
            let model = BackgroundWorkCenterModel()
            weakModel = model
            _ = model.begin(.semanticIndex, stage: .semanticIndexing)
        }
        XCTAssertNil(weakModel)
    }
}
