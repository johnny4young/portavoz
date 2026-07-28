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
    func testAddTrimsAndNeverDuplicatesCaseInsensitively() {
        let model = RecordingObjectivesModel()
        model.add("  Cerrar el presupuesto  ")
        model.add("cerrar el presupuesto")
        model.add("   ")
        XCTAssertEqual(model.objectives.map(\.text), ["Cerrar el presupuesto"])
    }

    func testManualToggleChecksUnchecksAndClearsTheModelMark() {
        let model = RecordingObjectivesModel()
        model.add("Definir el alcance")
        let id = model.objectives[0].id

        model.toggle(id, elapsed: 120)
        XCTAssertEqual(model.objectives[0].checkedAt, 120)
        XCTAssertFalse(model.objectives[0].checkedByModel)
        XCTAssertTrue(model.pending.isEmpty)

        model.toggle(id, elapsed: 300)
        XCTAssertNil(model.objectives[0].checkedAt, "a second toggle unchecks")
    }

    func testContextItemsFoldCheckOffStateIntoContent() {
        let model = RecordingObjectivesModel()
        model.add("Acordar la fecha")
        model.add("Revisar riesgos")
        model.toggle(model.objectives[0].id, elapsed: 95)

        let meetingID = MeetingID()
        let items = model.contextItems(meetingID: meetingID)
        XCTAssertEqual(items.map(\.kind), [.objective, .objective])
        XCTAssertEqual(items[0].content, "\u{2713} Acordar la fecha")
        XCTAssertEqual(items[0].timestamp, 95)
        XCTAssertEqual(items[1].content, "Revisar riesgos")
        XCTAssertEqual(items[1].timestamp, 0, "a pending objective anchors at the start")
        XCTAssertTrue(items.allSatisfy { $0.meetingID == meetingID })
    }

    func testResetClearsEverything() {
        let model = RecordingObjectivesModel()
        model.add("Uno")
        model.reset()
        XCTAssertTrue(model.objectives.isEmpty)
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
