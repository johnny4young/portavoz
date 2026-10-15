import XCTest

extension ArchitectureDependencyTests {
    func testTranscriptPresentationDerivesOnlyAtOwnedInputBoundaries() throws {
        let model = try Self.contents(of: "Sources/portavoz-app/MeetingDetailModel.swift")
        let view = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let projection = try Self.contents(of: "Sources/portavoz-app/MeetingDetailTranscriptPresentation.swift")

        XCTAssertTrue(model.contains("if case .core = update"))
        XCTAssertTrue(model.contains("next.transcriptPresentationState.receiveCore("))
        XCTAssertTrue(model.contains("resetChapterTitles: transition.correctionRevisionChanged"))
        XCTAssertTrue(model.contains("next.transcriptPresentationState.mergeChapterTitles("))
        XCTAssertTrue(projection.contains("guard merged != chapterTitles else { return false }"))
        XCTAssertEqual(projection.components(separatedBy: "MeetingDetailTranscriptPresentation(detail:").count - 1, 2)
        XCTAssertTrue(projection.contains("presentation = detail.map"))
        XCTAssertTrue(projection.contains("if resetChapterTitles { chapterTitles = [:] }"))
        XCTAssertTrue(model.contains("state = next"))
        XCTAssertTrue(view.contains("transcriptPresentation.current"))
        XCTAssertTrue(view.contains("transcriptPresentation.structure"))
        XCTAssertEqual(view.components(separatedBy: "model.state.transcriptPresentation?.current").count - 1, 3)
        for repeatedDerivation in [".transcriptContent(", ".acceptedTranscriptContent(", ".transcriptStructureProjection("] {
            XCTAssertFalse(view.contains(repeatedDerivation), repeatedDerivation)
            XCTAssertTrue(projection.contains(repeatedDerivation), repeatedDerivation)
        }
        for forbidden in ["import SwiftUI", "@Observable", "static var", "Task", "UserDefaults", "corrections.isEmpty"] {
            XCTAssertFalse(projection.contains(forbidden), forbidden)
        }
    }
}
