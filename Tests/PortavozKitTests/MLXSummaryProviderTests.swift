import Foundation
import IntelligenceKit
import PortavozCore
import XCTest

final class MLXSummaryProviderTests: XCTestCase {
    func testProviderUsesInjectedRuntimeAndPreservesFingerprint() async throws {
        let directory = URL(
            fileURLWithPath: "/verified/qwen",
            isDirectory: true)
        let runtime = MLXRuntimeClientSpy(response: """
            {
              "overview": "Runtime injection works.",
              "sections": [],
              "actionItems": []
            }
            """)
        let meetingID = MeetingID()
        let request = SummaryRequest(
            meetingID: meetingID,
            segments: [],
            speakers: [],
            recipe: .general,
            targetLanguage: "en")

        let draft = try await MLXSummaryProvider(
            modelDirectory: directory,
            runtime: runtime)
            .summarize(request)

        let capturedCall = await runtime.lastCall()
        let call = try XCTUnwrap(capturedCall)
        XCTAssertEqual(call.directory, directory)
        XCTAssertFalse(call.system.isEmpty)
        XCTAssertFalse(call.user.isEmpty)
        XCTAssertEqual(draft.meetingID, meetingID)
        XCTAssertEqual(draft.markdown, "Runtime injection works.")
        XCTAssertEqual(
            draft.fingerprint,
            SummaryFingerprint.compute(
                request: request,
                providerID: MLXSummaryProvider.providerID))
    }

    func testOnDeviceNotesAndMaterialBudgetsStayBoundedWithinContextWindow() {
        XCTAssertEqual(
            TranscriptFormatter.onDeviceReduceMaterialBudget(notesCharacterCount: 0),
            TranscriptFormatter.onDeviceReduceBudget)
        XCTAssertEqual(
            TranscriptFormatter.onDeviceReduceMaterialBudget(notesCharacterCount: 400),
            TranscriptFormatter.onDeviceReduceBudget - 400)
        // Oversized notes condense to `onDeviceNotesBudget`, leaving enough
        // room for transcript material instead of overflowing the 4,096-token window.
        XCTAssertEqual(
            TranscriptFormatter.onDeviceReduceMaterialBudget(notesCharacterCount: 5_000),
            TranscriptFormatter.onDeviceReduceBudget - TranscriptFormatter.onDeviceNotesBudget)
        XCTAssertGreaterThanOrEqual(
            TranscriptFormatter.onDeviceReduceMaterialBudget(
                notesCharacterCount: 5_000,
                totalBudget: 1_000),
            TranscriptFormatter.onDeviceRetryFloor)
    }
}

private actor MLXRuntimeClientSpy: MLXSummaryRuntimeClient {
    struct Call: Sendable {
        let system: String
        let user: String
        let directory: URL
    }

    private let response: String
    private var call: Call?

    init(response: String) {
        self.response = response
    }

    func respond(
        system: String,
        user: String,
        directory: URL
    ) -> String {
        call = Call(
            system: system,
            user: user,
            directory: directory)
        return response
    }

    func lastCall() -> Call? {
        call
    }
}
