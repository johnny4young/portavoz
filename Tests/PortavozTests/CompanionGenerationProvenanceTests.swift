import Foundation
import IntelligenceKit
import PortavozCore
import XCTest

final class CompanionGenerationProvenanceTests: XCTestCase {
    private let meetingID = MeetingID(
        rawValue: UUID(uuidString: "C3000000-0000-0000-0000-000000000001")!)
    private let runID = GenerationRunID(
        rawValue: UUID(uuidString: "C3000000-0000-0000-0000-000000000002")!)
    private let startedAt = Date(timeIntervalSince1970: 1_783_700_000)

    func testFingerprintBindsOrderedPrivateMaterialAndProviderConfiguration() throws {
        let first = request()
        let base = try XCTUnwrap(CompanionGenerationOperationFingerprint.compute(
            request: first,
            externalProvider: externalProvider))

        XCTAssertEqual(base, CompanionGenerationOperationFingerprint.compute(
            request: first,
            externalProvider: externalProvider))
        XCTAssertNotEqual(base, CompanionGenerationOperationFingerprint.compute(
            request: request(candidate: "¿Qué cambió en el presupuesto?"),
            externalProvider: externalProvider))
        XCTAssertNotEqual(base, CompanionGenerationOperationFingerprint.compute(
            request: request(passages: Array(first.recentTranscript.reversed())),
            externalProvider: externalProvider))
        XCTAssertNotEqual(base, CompanionGenerationOperationFingerprint.compute(
            request: first,
            externalProvider: nil))
        XCTAssertNotEqual(base, CompanionGenerationOperationFingerprint.compute(
            request: first,
            externalProvider: CompanionExternalProviderIdentity(
                providerID: externalProvider.providerID,
                modelID: externalProvider.modelID,
                destinationIdentity: "https://api.example.com/another-base")))
    }

    func testAttemptRecordsContentFreeProviderEgressAndAggregateMetrics() throws {
        let request = request()
        let attempt = try XCTUnwrap(CompanionGenerationAttempt(
            id: runID,
            request: request,
            externalProvider: externalProvider,
            startedAt: startedAt))
        let card = CompanionCard(
            question: "¿Cuándo sale?",
            answer: "Mañana.",
            kind: .context,
            source: "api.example.com",
            directed: true,
            askedAt: 12)
        let trace = CompanionProcessTrace(
            classifierInvoked: true,
            answerProviderID: "api.example.com",
            answerModelID: "companion-model",
            externalDestinationScope: .remote,
            externalTransferOccurred: true,
            externalTransferSucceeded: true)

        let run = attempt.finish(
            outcome: .succeeded,
            trace: trace,
            card: card,
            at: startedAt.addingTimeInterval(2))

        XCTAssertEqual(run.id, runID)
        XCTAssertEqual(run.kind, .companion)
        XCTAssertEqual(run.providerID, "api.example.com")
        XCTAssertEqual(run.modelID, "companion-model")
        XCTAssertEqual(run.outputLanguage, "es")
        XCTAssertEqual(run.outcome, .succeeded)
        XCTAssertTrue(run.configJSON.contains(#""externalTransferOccurred":true"#))
        XCTAssertTrue(run.configJSON.contains(#""externalDestinationScope":"remote""#))
        XCTAssertTrue(run.configJSON.contains(#""workflow":"post-refine""#))
        XCTAssertTrue(run.metricsJSON?.contains(#""answerUTF8Bytes":8"#) == true)
        for privateText in ["Johnny", "¿Cuándo se aprueba?", "El viernes.", "Mañana."] {
            XCTAssertFalse(run.configJSON.contains(privateText))
            XCTAssertFalse(run.metricsJSON?.contains(privateText) == true)
        }
    }

    func testAttemptRecordsExternalFailureThenOnDeviceFallback() throws {
        let attempt = try XCTUnwrap(CompanionGenerationAttempt(
            id: runID,
            request: request(),
            externalProvider: externalProvider,
            startedAt: startedAt))
        let card = CompanionCard(
            question: "¿Cuándo sale?",
            answer: "Mañana.",
            kind: .knowledge,
            source: "on-device",
            askedAt: 12)
        let trace = CompanionProcessTrace(
            classifierInvoked: true,
            answerProviderID: CompanionGenerationAttempt.foundationProviderID,
            answerModelID: CompanionGenerationAttempt.foundationModelID,
            externalDestinationScope: .remote,
            externalTransferOccurred: true,
            externalTransferSucceeded: false)

        let run = attempt.finish(
            outcome: .succeeded,
            trace: trace,
            card: card,
            at: startedAt.addingTimeInterval(2))

        XCTAssertEqual(run.providerID, CompanionGenerationAttempt.foundationProviderID)
        XCTAssertEqual(run.modelID, CompanionGenerationAttempt.foundationModelID)
        XCTAssertTrue(run.configJSON.contains(#""externalDestinationScope":"remote""#))
        XCTAssertTrue(run.configJSON.contains(#""externalTransferOccurred":true"#))
        XCTAssertTrue(run.configJSON.contains(#""externalTransferSucceeded":false"#))
    }

    func testCancelledExternalAttemptKeepsProviderAndHasNoContentMetrics() throws {
        let attempt = try XCTUnwrap(CompanionGenerationAttempt(
            id: runID,
            request: request(),
            externalProvider: externalProvider,
            startedAt: startedAt))
        let trace = CompanionProcessTrace(
            classifierInvoked: true,
            answerProviderID: externalProvider.providerID,
            answerModelID: externalProvider.modelID,
            externalDestinationScope: .remote,
            externalTransferOccurred: true,
            externalTransferSucceeded: false)

        let run = attempt.finish(
            outcome: .cancelled,
            trace: trace,
            card: nil,
            at: startedAt.addingTimeInterval(1))

        XCTAssertEqual(run.providerID, externalProvider.providerID)
        XCTAssertEqual(run.modelID, externalProvider.modelID)
        XCTAssertEqual(run.outcome, .cancelled)
        XCTAssertTrue(run.configJSON.contains(#""externalDestinationScope":"remote""#))
        XCTAssertNil(run.metricsJSON)
    }

    private var externalProvider: CompanionExternalProviderIdentity {
        CompanionExternalProviderIdentity(
            providerID: "api.example.com",
            modelID: "companion-model",
            destinationIdentity: "https://api.example.com/v1")
    }

    private func request(
        candidate: String = "Johnny, ¿cuándo se aprueba?",
        passages: [RAGPassage] = [
            RAGPassage(
                meetingID: MeetingID(
                    rawValue: UUID(
                        uuidString: "C3000000-0000-0000-0000-000000000001")!),
                meetingTitle: "This meeting",
                timestamp: 5,
                text: "Them: El viernes."),
            RAGPassage(
                meetingID: MeetingID(
                    rawValue: UUID(
                        uuidString: "C3000000-0000-0000-0000-000000000001")!),
                meetingTitle: "This meeting",
                timestamp: 8,
                text: "Me: Confirmado."),
        ]
    ) -> CompanionGenerationRequest {
        CompanionGenerationRequest(
            meetingID: meetingID,
            sourceTranscriptRevision: 5,
            workflow: .postRefine,
            candidate: candidate,
            recentTranscript: passages,
            ownerName: "Johnny",
            outputLanguage: "es",
            askedAt: 12)
    }
}
