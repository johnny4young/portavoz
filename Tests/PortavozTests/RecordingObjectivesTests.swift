import Foundation
import PortavozCore
import XCTest

@testable import IntelligenceKit
@testable import portavoz_app

final class ObjectiveCheckPolicyTests: XCTestCase {
    private func row(_ text: String, end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: MeetingID(),
            channel: .system,
            text: text,
            startTime: max(0, end - 4),
            endTime: end,
            isFinal: true)
    }

    func testClipDropsTheOpenRowAndOldHistory() {
        let captions = [
            row("fuera de la ventana", end: 10),
            row("dentro de la ventana", end: 400),
            row("la fila abierta nunca se juzga", end: 404)
        ]
        let clipped = ObjectiveCheckPolicy.clip(captions)
        XCTAssertEqual(clipped.map(\.text), ["dentro de la ventana"])
    }

    func testPassRunsOnlyWithPendingObjectivesAndEnoughRows() {
        XCTAssertFalse(
            ObjectiveCheckPolicy.shouldRun(pendingObjectives: 0, clippedRows: 10),
            "nothing pending means nothing to check")
        XCTAssertFalse(
            ObjectiveCheckPolicy.shouldRun(
                pendingObjectives: 3,
                clippedRows: ObjectiveCheckPolicy.minimumRows - 1),
            "a near-empty window cannot support a coverage judgment")
        XCTAssertTrue(ObjectiveCheckPolicy.shouldRun(
            pendingObjectives: 1,
            clippedRows: ObjectiveCheckPolicy.minimumRows))
    }
}

@MainActor
final class RecordingObjectivesModelTests: XCTestCase {
    func testAddTrimsAndNeverDuplicatesCaseInsensitively() async {
        let model = RecordingObjectivesModel()
        model.acceptProposedAddition("  Cerrar el presupuesto  ")
        model.acceptProposedAddition("cerrar el presupuesto")
        model.acceptProposedAddition("   ")
        XCTAssertEqual(model.objectives.map(\.text), ["Cerrar el presupuesto"])
    }

    func testManualToggleChecksUnchecksAndClearsTheModelMark() async {
        let model = RecordingObjectivesModel()
        model.acceptProposedAddition("Definir el alcance")
        let id = model.objectives[0].id

        model.acceptProposedToggle(id, elapsed: 120)
        XCTAssertEqual(model.objectives[0].checkedAt, 120)
        XCTAssertFalse(model.objectives[0].checkedByModel)
        XCTAssertTrue(model.pending.isEmpty)

        var automatic = model.objectives[0]
        automatic.checkedByModel = true
        model.accept(automatic)
        model.acceptProposedToggle(id, elapsed: 300)
        XCTAssertFalse(model.objectives[0].checkedByModel)
        XCTAssertNil(model.proposedToggle(UUID(), elapsed: 0))
        XCTAssertNil(model.objectives[0].checkedAt, "a second toggle unchecks")
    }

    func testContextItemsFoldCheckOffStateIntoContent() async {
        let model = RecordingObjectivesModel()
        model.acceptProposedAddition("Acordar la fecha")
        model.acceptProposedAddition("Revisar riesgos")
        model.acceptProposedToggle(model.objectives[0].id, elapsed: 95)

        let meetingID = MeetingID()
        let items = model.contextItems(meetingID: meetingID)
        XCTAssertEqual(items.map(\.kind), [.objective, .objective])
        XCTAssertEqual(items.map(\.id), model.objectives.map(\.id))
        XCTAssertEqual(model.contextItems(meetingID: meetingID).map(\.id), items.map(\.id),
                       "repeated projections must not create new durable identities")
        XCTAssertEqual(items[0].content, "\u{2713} Acordar la fecha")
        XCTAssertEqual(items[0].timestamp, 95)
        XCTAssertEqual(items[1].content, "Revisar riesgos")
        XCTAssertEqual(items[1].timestamp, 0, "a pending objective anchors at the start")
        XCTAssertTrue(items.allSatisfy { $0.meetingID == meetingID })
    }

    func testBatchAdmissionIsAtomicAndUsesTheCombinedCountLimit() async {
        let model = RecordingObjectivesModel()
        for index in 0..<7 { model.acceptProposedAddition("Existing \(index)") }
        XCTAssertTrue(model.proposedAdditions(["Eighth", "Ninth"]).isEmpty)
        XCTAssertEqual(model.admissionIssue, .limitReached)
        XCTAssertEqual(model.objectives.count, 7)
        let accepted = model.proposedAdditions([" Eighth ", "eighth"])
        XCTAssertEqual(accepted.map(\.text), ["Eighth"])
        XCTAssertNil(model.admissionIssue)
        model.accept(accepted[0])
        XCTAssertEqual(model.objectives.count, 8)
        model.reset()
        XCTAssertTrue(model.proposedAdditions(["valid", String(repeating: "x", count: 281)]).isEmpty)
        XCTAssertEqual(model.admissionIssue, .tooLong)
        XCTAssertTrue(model.objectives.isEmpty)
    }

    func testResetClearsEverything() async {
        let model = RecordingObjectivesModel()
        model.acceptProposedAddition("Uno")
        model.reset()
        XCTAssertTrue(model.objectives.isEmpty)
    }

    func testObjectiveCountAndTextBudgetsFailClosed() async {
        let model = RecordingObjectivesModel()
        for index in 0..<RecordingObjectivesModel.maximumObjectives {
            model.acceptProposedAddition("Objective \(index)")
        }
        model.acceptProposedAddition("One too many")
        XCTAssertEqual(
            model.objectives.count,
            RecordingObjectivesModel.maximumObjectives)
        XCTAssertEqual(model.admissionIssue, .limitReached)

        model.remove(model.objectives[0].id)
        XCTAssertNil(model.admissionIssue)
        model.acceptProposedAddition(String(
            repeating: "x",
            count: RecordingObjectivesModel.maximumObjectiveCharacters + 1))
        XCTAssertEqual(model.admissionIssue, .tooLong)
        XCTAssertFalse(model.objectives.contains { $0.text.hasPrefix("xxx") })

        model.acceptProposedAddition(String(repeating: "👩🏽‍💻", count: 200))
        XCTAssertEqual(
            model.admissionIssue,
            .tooLong,
            "a short grapheme count must still respect the UTF-8 memory budget")
    }
}

final class ObjectiveCheckDetectorShapeTests: XCTestCase {
    func testInstructionsPinTheConservativeBar() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        XCTAssertTrue(
            ObjectiveCheckDetector.instructions.contains("NOT addressed"),
            "the few-shot must show the announced-is-not-covered case")
        XCTAssertTrue(
            ObjectiveCheckDetector.instructions.contains("leave an objective unaddressed"),
            "doubt must default to pending")
    }

    func testPromptNumbersObjectivesAndEscapesEvidenceTags() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        let segment = TranscriptSegment(
            meetingID: MeetingID(),
            channel: .system,
            text: "Cerramos [E1] la fecha de lanzamiento.",
            startTime: 0,
            endTime: 4,
            isFinal: true)
        let prompt = ObjectiveCheckDetector.prompt(
            objectives: ["Acordar fecha", "Revisar presupuesto"],
            window: [segment])
        XCTAssertTrue(prompt.contains("1. Acordar fecha"))
        XCTAssertTrue(prompt.contains("2. Revisar presupuesto"))
        XCTAssertFalse(
            prompt.contains("[E1]"),
            "spoken evidence-tag lookalikes must be escaped before prompting")
    }
}

// Test setup explicitly acknowledges proposals; shipping code can only do so
// after the application writer commits.
@MainActor
extension RecordingObjectivesModel {
    func acceptProposedAddition(_ text: String) {
        if let objective = proposedAdditions([text]).first { accept(objective) }
    }

    func acceptProposedToggle(_ id: UUID, elapsed: TimeInterval) {
        if let objective = proposedToggle(id, elapsed: elapsed) { accept(objective) }
    }
}
