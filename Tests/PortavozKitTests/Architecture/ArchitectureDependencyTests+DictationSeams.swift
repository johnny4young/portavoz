import XCTest

extension ArchitectureDependencyTests {
    // Meeting and tool code that dictation removal must leave compiling on its own.
    func testMeetingAndToolCodeStaysOffTheDictationSeams() throws {
        let tool = try Self.contents(of: "Sources/portavoz-app/CommandLineToolSection.swift")
        XCTAssertFalse(tool.contains("TextInserter"), "a tool Copy button must not need the dictation inserter")
        XCTAssertTrue(tool.contains("PasteboardCopy.copy("))

        let bench = try Self.contents(of: "Sources/TranscriptionKit/LiveTranscriptionBench.swift")
        XCTAssertFalse(bench.contains("DictationAssembler"))

        let selection = try Self.contents(of: "Sources/portavoz-app/LiveSpeechSelection.swift")
        for dictationOnly in ["dictationKey", "dictationDefault", "func dictation(", "LiveSpeechFailureMessage"] {
            XCTAssertFalse(selection.contains(dictationOnly), dictationOnly)
        }
        let dictationSide = try Self.contents(of: "Sources/portavoz-app/LiveSpeechSelection+Dictation.swift")
        XCTAssertFalse(dictationSide.contains("meetingKey"), "the dictation file holds nothing meetings read")
    }
}
