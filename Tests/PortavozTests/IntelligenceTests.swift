import Foundation
import PortavozCore
import XCTest

@testable import IntelligenceKit

// MARK: - Prompts

final class PromptFactoryTests: XCTestCase {
    func testSummaryInstructionsCarryRecipeLanguageAndGlossary() {
        let instructions = PromptFactory.summaryInstructions(
            recipe: .general, targetLanguage: "es", glossary: ["Parakeet", "rollback"])

        for section in Recipe.general.sections {
            XCTAssertTrue(instructions.contains(section), "missing section \(section)")
        }
        XCTAssertTrue(instructions.contains("Spanish (español)"))
        XCTAssertTrue(instructions.contains("Parakeet, rollback"))
        XCTAssertTrue(instructions.contains("never invent"))
        XCTAssertTrue(instructions.contains("\"Me\" is the device owner"))
    }

    /// The language reminder must ride at the END of the user prompt —
    /// the on-device model ignores it when it only lives in instructions.
    func testSummaryPromptEndsWithLanguageReminder() {
        let prompt = PromptFactory.summaryPrompt(transcriptOrNotes: "texto", targetLanguage: "es")
        XCTAssertTrue(prompt.contains("texto"))
        XCTAssertTrue(prompt.hasSuffix("in Spanish (español), including every heading and bullet."))
    }

    func testLanguageNames() {
        XCTAssertEqual(PromptFactory.languageName(for: "es"), "Spanish (español)")
        XCTAssertEqual(PromptFactory.languageName(for: "en"), "English")
        XCTAssertEqual(PromptFactory.languageName(for: "zz-weird"), "zz-weird")
    }

    func testGlossaryDirectiveOmittedWhenEmpty() {
        let directive = PromptFactory.languageDirective(targetLanguage: "en", glossary: [])
        XCTAssertFalse(directive.contains("never translated"))
    }

    func testNotesPromptNumbersChunks() {
        let prompt = PromptFactory.notesPrompt(chunk: "texto", index: 1, total: 3)
        XCTAssertTrue(prompt.contains("2 of 3"))
        XCTAssertTrue(prompt.contains("texto"))
    }
}

// MARK: - Transcript formatting

final class TranscriptFormatterTests: XCTestCase {
    private let meeting = MeetingID()

    func testFormatUsesSpeakerLabelsAndTimestamps() {
        let me = Speaker(meetingID: meeting, label: "Me", isMe: true)
        let other = Speaker(meetingID: meeting, label: "S1", displayName: "Ana")
        let segments = [
            TranscriptSegment(
                meetingID: meeting, speakerID: me.id, channel: .microphone,
                text: "hola a todos", startTime: 0, endTime: 2),
            TranscriptSegment(
                meetingID: meeting, speakerID: other.id, channel: .system,
                text: "buenos días", startTime: 62, endTime: 64),
            TranscriptSegment(
                meetingID: meeting, channel: .system,
                text: "sin atribuir", startTime: 65, endTime: 66),
        ]
        let text = TranscriptFormatter.format(segments: segments, speakers: [me, other])
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "[00:00] Me: hola a todos")
        XCTAssertEqual(lines[1], "[01:02] Ana: buenos días")  // displayName wins
        XCTAssertEqual(lines[2], "[01:05] system?: sin atribuir")
    }

    func testChunkingRespectsBudgetAndLineBoundaries() {
        let line = String(repeating: "x", count: 100)
        let transcript = Array(repeating: line, count: 25).joined(separator: "\n")

        let chunks = TranscriptFormatter.chunk(transcript, budget: 550)
        XCTAssertGreaterThan(chunks.count, 3)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 550)
            // No partial lines: every chunk is whole 100-char lines.
            for chunkLine in chunk.split(separator: "\n") {
                XCTAssertEqual(chunkLine.count, 100)
            }
        }
        // Nothing lost.
        let total = chunks.map { $0.split(separator: "\n").count }.reduce(0, +)
        XCTAssertEqual(total, 25)
    }

    func testShortTranscriptIsOneChunk() {
        XCTAssertEqual(TranscriptFormatter.chunk("corto", budget: 100), ["corto"])
        XCTAssertEqual(TranscriptFormatter.chunk("", budget: 100), [])
    }
}

// MARK: - Structured summary

final class StructuredSummaryTests: XCTestCase {
    private let meeting = MeetingID()

    private var summary: StructuredSummary {
        StructuredSummary(
            overview: "Se acordó el plan de Q3.",
            sections: [
                .init(heading: "Decisions", bullets: ["Adoptar Parakeet"]),
                .init(heading: "Open Questions", bullets: []),  // omitted in markdown
            ],
            actionItems: [
                .init(text: "Preparar el rollback plan", owner: "S1"),
                .init(text: "Revisar el budget", owner: ""),
            ]
        )
    }

    func testMarkdownRenderingSkipsEmptySectionsAndMarksOwners() {
        let markdown = summary.markdown(recipe: .general)
        XCTAssertTrue(markdown.hasPrefix("Se acordó el plan de Q3."))
        XCTAssertTrue(markdown.contains("## Decisions\n- Adoptar Parakeet"))
        XCTAssertFalse(markdown.contains("Open Questions"))
        XCTAssertTrue(markdown.contains("- [ ] Preparar el rollback plan — S1"))
        XCTAssertTrue(markdown.contains("- [ ] Revisar el budget\n") || markdown.hasSuffix("- [ ] Revisar el budget"))
    }

    func testDraftResolvesOwnersCaseInsensitively() {
        let ana = Speaker(meetingID: meeting, label: "s1", displayName: "Ana")
        let request = SummaryRequest(
            meetingID: meeting, segments: [], speakers: [ana],
            recipe: .general, targetLanguage: "es", glossary: [])

        let draft = summary.draft(for: request)
        XCTAssertEqual(draft.language, "es")
        XCTAssertEqual(draft.actionItems.count, 2)
        XCTAssertEqual(draft.actionItems[0].ownerSpeakerID, ana.id)  // "S1" vs "s1"
        XCTAssertNil(draft.actionItems[1].ownerSpeakerID)
    }
}

// MARK: - Foundation Models integration (gated)

final class FoundationModelIntegrationTests: XCTestCase {
    /// Full on-device summary in Spanish with glossary. Needs
    /// PORTAVOZ_MODEL_TESTS=1, macOS 26+, and Apple Intelligence enabled.
    func testSpanishSummaryOfEnglishMeetingKeepsGlossary() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_MODEL_TESTS"] == "1",
            "set PORTAVOZ_MODEL_TESTS=1 to run")
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw XCTSkip("Apple Intelligence unavailable: \(reason)")
        }

        let meeting = MeetingID()
        let me = Speaker(meetingID: meeting, label: "Me", isMe: true)
        let ana = Speaker(meetingID: meeting, label: "S1")
        func line(_ speaker: Speaker, _ text: String, _ at: TimeInterval) -> TranscriptSegment {
            TranscriptSegment(
                meetingID: meeting, speakerID: speaker.id,
                channel: speaker.isMe ? .microphone : .system,
                text: text, startTime: at, endTime: at + 4, isFinal: true)
        }
        let request = SummaryRequest(
            meetingID: meeting,
            segments: [
                line(me, "Let's review the roadmap for the transcription milestone.", 0),
                line(ana, "The latency looks good. I will prepare the rollout plan by Friday.", 5),
                line(me, "Great, then we ship the beta next week.", 10),
            ],
            speakers: [me, ana],
            recipe: .general,
            targetLanguage: "es",
            glossary: ["roadmap", "beta"]
        )

        let draft = try await FoundationModelSummaryProvider().summarize(request)

        XCTAssertEqual(draft.language, "es")
        XCTAssertFalse(draft.markdown.isEmpty)
        XCTAssertTrue(
            draft.markdown.contains("roadmap") || draft.markdown.contains("beta"),
            "glossary terms must survive: \(draft.markdown)")
    }

    /// A transcript bigger than one model window must go through the
    /// map-reduce (notes) path and still come out structured.
    func testLongTranscriptTakesTheIncrementalPath() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_MODEL_TESTS"] == "1",
            "set PORTAVOZ_MODEL_TESTS=1 to run")
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw XCTSkip("Apple Intelligence unavailable: \(reason)")
        }

        let meeting = MeetingID()
        let me = Speaker(meetingID: meeting, label: "Me", isMe: true)
        let ana = Speaker(meetingID: meeting, label: "S1")
        let topics = [
            "the migration to the new storage layer and its rollback plan",
            "hiring two engineers for the audio team before October",
            "the latency regression found in the beta and how it was fixed",
            "renewing the office lease versus going fully remote",
            "the pricing change for the pro tier and its rollout schedule",
        ]
        // ~40 segments ≈ 3 model windows.
        var segments: [TranscriptSegment] = []
        for (round, topic) in topics.enumerated() {
            for turn in 0..<8 {
                let speaker = turn.isMultiple(of: 2) ? me : ana
                let at = TimeInterval(round * 400 + turn * 45)
                segments.append(
                    TranscriptSegment(
                        meetingID: meeting, speakerID: speaker.id,
                        channel: speaker.isMe ? .microphone : .system,
                        text:
                            "Regarding \(topic), point \(turn + 1): we compared the options in detail, "
                            + "looked at the numbers from last quarter, and weighed the risks the team raised earlier.",
                        startTime: at, endTime: at + 40, isFinal: true))
            }
        }
        let transcript = TranscriptFormatter.format(segments: segments, speakers: [me, ana])
        XCTAssertGreaterThan(
            TranscriptFormatter.chunk(transcript, budget: TranscriptFormatter.onDeviceChunkBudget).count,
            1, "fixture must overflow one window to exercise map-reduce")

        let request = SummaryRequest(
            meetingID: meeting, segments: segments, speakers: [me, ana],
            recipe: .general, targetLanguage: "en", glossary: [])
        let draft = try await FoundationModelSummaryProvider().summarize(request)

        XCTAssertFalse(draft.markdown.isEmpty)
        XCTAssertTrue(draft.markdown.contains("##"), "expected structured sections")
    }
}

// MARK: - BYOK provider (offline)

final class OpenAICompatibleProviderTests: XCTestCase {
    private let meeting = MeetingID()

    func testRequestBodyIsOpenAICompatibleAndLabeled() throws {
        let request = SummaryRequest(
            meetingID: meeting,
            segments: [
                TranscriptSegment(
                    meetingID: meeting, channel: .system, text: "hola",
                    startTime: 0, endTime: 1)
            ],
            speakers: [],
            recipe: .general,
            targetLanguage: "es",
            glossary: ["deploy"]
        )
        let urlRequest = try OpenAICompatibleSummaryProvider.urlRequest(
            for: request,
            endpoint: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "sk-123")

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sk-123")

        let body = try JSONSerialization.jsonObject(with: urlRequest.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "test-model")
        let messages = body["messages"] as! [[String: String]]
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0]["content"]!.contains("deploy"))
        XCTAssertTrue(messages[0]["content"]!.contains("JSON"))
        XCTAssertTrue(messages[1]["content"]!.contains("hola"))
    }

    func testParsesFencedJSONResponses() throws {
        let payload = """
            {"choices": [{"message": {"content": "```json\\n{\\"overview\\": \\"ok\\", \\"sections\\": [], \\"actionItems\\": []}\\n```"}}]}
            """
        let summary = try OpenAICompatibleSummaryProvider.parseResponse(Data(payload.utf8))
        XCTAssertEqual(summary.overview, "ok")
    }

    func testRejectsNonJSONContent() {
        let payload = """
            {"choices": [{"message": {"content": "I cannot help with that."}}]}
            """
        XCTAssertThrowsError(
            try OpenAICompatibleSummaryProvider.parseResponse(Data(payload.utf8)))
    }
}

final class LiveSummaryPolicyTests: XCTestCase {
    func testFirstRenderAlwaysShows() {
        XCTAssertTrue(LiveSummaryPolicy.shouldReplace(current: nil, candidate: "## Resumen"))
        XCTAssertTrue(LiveSummaryPolicy.shouldReplace(current: "", candidate: "## Resumen"))
    }

    func testEmptyCandidateNeverReplaces() {
        XCTAssertFalse(LiveSummaryPolicy.shouldReplace(current: "algo", candidate: ""))
        XCTAssertFalse(LiveSummaryPolicy.shouldReplace(current: nil, candidate: ""))
    }

    func testShrunkenRenderIsHeldBack() {
        let current = String(repeating: "x", count: 1000)
        let shrunken = String(repeating: "x", count: 500)
        XCTAssertFalse(LiveSummaryPolicy.shouldReplace(current: current, candidate: shrunken))
    }

    func testComparableOrLongerRenderReplaces() {
        let current = String(repeating: "x", count: 1000)
        XCTAssertTrue(
            LiveSummaryPolicy.shouldReplace(
                current: current, candidate: String(repeating: "y", count: 950)))
        XCTAssertTrue(
            LiveSummaryPolicy.shouldReplace(
                current: current, candidate: String(repeating: "y", count: 1400)))
    }
}
