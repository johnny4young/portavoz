import Foundation
import XCTest

extension ArchitectureDependencyTests {
    // Dictation lives in Secreteo; Portavoz keeps only what a 1.x library needs.
    func testNoDictationRuntimeRemains() throws {
        let app = try XCTUnwrap(FileManager.default.enumerator(
            atPath: Self.repoRoot.appendingPathComponent("Sources/portavoz-app").path))
            .compactMap { $0 as? String }
            .filter { $0.contains("Dictation") }
        XCTAssertEqual(
            app.filter { !$0.hasPrefix("LegacyDictation") }, [],
            "only the legacy retention, notice and ownership release stay in the app")

        let runtime = #"DictationController|DictationOwnershipCoordinator|DictationAdmission|TextInserter|"#
            + #"GlobalHotkey|SelectionRewrite|parakeetUltra|ParakeetCheckpoint|filtersLiveScript|"#
            + #"LiveSpeechPurpose|LiveSpeechCheckpointPlan|beginDictationCapture|dictationOwners"#
        XCTAssertEqual(try Self.sourceMatches(under: "Sources", pattern: runtime, codeOnly: true), [])

        let tool = try Self.contents(of: "Sources/portavoz-app/CommandLineToolSection.swift")
        XCTAssertTrue(tool.contains("PasteboardCopy.copy("))
        let bench = try Self.contents(of: "Sources/TranscriptionKit/LiveTranscriptionBench.swift")
        XCTAssertFalse(bench.contains("DictationAssembler"))
    }
}
