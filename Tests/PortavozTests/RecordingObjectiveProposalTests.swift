import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class RecordingObjectiveProposalTests: XCTestCase {
    func testDetectorDuplicatesAndInvalidIndexesCannotDuplicateDurableIdentities() async {
        let captions = rows()
        let model = RecordingObjectivesModel { objectives, window in
            XCTAssertEqual(objectives, ["Check the owner’s approval", "Confirmar quién decide"])
            XCTAssertEqual(window.map(\.id), Array(captions.dropLast()).map(\.id))
            return [-1, 0, 0, 1, 2, Int.max]
        }
        model.acceptProposedAddition("Check the owner’s approval")
        model.acceptProposedAddition("Confirmar quién decide")
        let ids = model.objectives.map(\.id)
        let changes = await model.automaticChanges(captions: captions, elapsed: 0)
        XCTAssertEqual(changes.map(\.id), ids)
        XCTAssertEqual(changes.map(\.checkedAt), [0, 0])
        XCTAssertTrue(changes.allSatisfy(\.checkedByModel))
        XCTAssertTrue(model.objectives.allSatisfy { $0.checkedAt == nil }, "a proposal is not an acknowledgement")
    }

    func testPendingDetectorCannotPublishAfterRemovalManualToggleOrCancellation() async {
        for action in ["replace", "toggle", "cancel"] {
            let entered = expectation(description: "detector entered: \(action)")
            let probe = CheckProbe()
            let model = RecordingObjectivesModel { _, _ in
                await withCheckedContinuation { continuation in
                    probe.continuation = continuation
                    entered.fulfill()
                }
            }
            model.acceptProposedAddition("Confirmar quién decide")
            let original = model.objectives[0]
            let task = Task { await model.automaticChanges(captions: rows(), elapsed: 8) }
            await fulfillment(of: [entered], timeout: 2)
            switch action {
            case "replace":
                model.remove(original.id)
                model.acceptProposedAddition(original.text)
                XCTAssertNotEqual(model.objectives[0].id, original.id)
            case "toggle":
                model.acceptProposedToggle(original.id, elapsed: 3)
                model.acceptProposedToggle(original.id, elapsed: 4)
            default:
                task.cancel()
            }
            probe.continuation?.resume(returning: [0])
            let changes = await task.value
            XCTAssertTrue(changes.isEmpty, action)
            XCTAssertTrue(model.objectives.allSatisfy { $0.checkedAt == nil }, action)
        }
    }

    private func rows() -> [TranscriptSegment] {
        let meetingID = MeetingID()
        return (0..<3).map { index in
            TranscriptSegment(meetingID: meetingID, channel: .system,
                              text: index == 2 ? "Still open" : "Decisión pendiente \(index)",
                              startTime: Double(index), endTime: Double(index + 1), isFinal: true)
        }
    }

    private final class CheckProbe {
        var continuation: CheckedContinuation<[Int], Never>?
    }
}
