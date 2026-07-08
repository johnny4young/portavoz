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

    /// D25 pivot: translating a finished snapshot must keep structure, the
    /// "▸ " coauthorship prefixes, the glossary, and the action-item count
    /// (owners ride positionally).
    func testTranslatePivotKeepsStructureAndItems() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_MODEL_TESTS"] == "1",
            "set PORTAVOZ_MODEL_TESTS=1 to run")
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw XCTSkip("Apple Intelligence unavailable: \(reason)")
        }

        let owner = SpeakerID()
        let pivot = SummaryDraft(
            meetingID: MeetingID(), recipeID: Recipe.general.id, language: "en",
            markdown: """
                The team reviewed the transcription roadmap and agreed to ship the beta next week.

                ## Decisions
                - ▸ The rollout plan is due Friday, owned by S1.
                - The beta ships next week if latency stays under budget.
                """,
            actionItems: [
                ActionItem(text: "Prepare the rollout plan by Friday", ownerSpeakerID: owner)
            ],
            fingerprint: "f-live")

        let draft = try await FoundationModelSummaryProvider().translate(
            pivot, to: "es", glossary: ["roadmap", "beta"])

        XCTAssertEqual(draft.language, "es")
        XCTAssertEqual(draft.fingerprint, "f-live", "the pivot's material identity carries over")
        XCTAssertTrue(draft.markdown.contains("▸"), "coauthorship prefixes must survive: \(draft.markdown)")
        XCTAssertTrue(
            draft.markdown.contains("roadmap") || draft.markdown.contains("beta"),
            "glossary must survive: \(draft.markdown)")
        XCTAssertEqual(draft.actionItems.count, 1)
        XCTAssertEqual(
            draft.actionItems.first?.ownerSpeakerID, owner,
            "owners ride positionally through the translation")
        XCTAssertNotEqual(
            draft.actionItems.first?.text, "Prepare the rollout plan by Friday",
            "the item text should actually be translated: \(draft.actionItems.first?.text ?? "")")
    }

    /// D26 "te preguntaron": a caption that names the owner produces a
    /// directed card even when it's pure logistics — and the same caption
    /// without a known owner keeps getting dropped by the logistics filter.
    func testDirectedQuestionsPingAndLogisticsStillDrops() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_MODEL_TESTS"] == "1",
            "set PORTAVOZ_MODEL_TESTS=1 to run")
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw XCTSkip("Apple Intelligence unavailable: \(reason)")
        }

        let companion = LiveCompanion()
        let meeting = MeetingID()
        let passages = [
            RAGPassage(
                meetingID: meeting, meetingTitle: "Esta reunión", timestamp: 5,
                text: "Ellos: mañana a las 10 es la demo con el cliente"),
            RAGPassage(
                meetingID: meeting, meetingTitle: "Esta reunión", timestamp: 9,
                text: "Yo: el build de la demo quedó listo hoy"),
        ]
        let ask = "Johnny, ¿nos acompañas mañana a la demo con el cliente?"

        // Named → card, marked directed, whatever branch answered it.
        let ping = try await companion.process(
            candidate: ask, recentTranscript: passages,
            ownerName: "Johnny Young", askedAt: 12)
        XCTAssertNotNil(ping, "a question aimed at the owner by name must never be dropped")
        XCTAssertEqual(ping?.directed, true)

        // No owner name → the logistics filter keeps doing its job.
        let dropped = try await companion.process(
            candidate: ask, recentTranscript: passages, askedAt: 12)
        XCTAssertNil(dropped, "logistics without a name match must stay silent: \(String(describing: dropped))")

        // Directed knowledge still gets a real answer.
        let knowledge = try await companion.process(
            candidate: "Johnny, ¿cuál es la diferencia entre var y let en Swift?",
            recentTranscript: passages, ownerName: "Johnny Young", askedAt: 20)
        XCTAssertEqual(knowledge?.directed, true)
        XCTAssertEqual(knowledge?.kind, .knowledge)
        XCTAssertFalse(knowledge?.answer.isEmpty ?? true)
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

// MARK: - Fingerprint cache + translation pivot (D25)

final class SummaryFingerprintTests: XCTestCase {
    private let meeting = MeetingID()

    private func request(
        text: String = "revisemos el presupuesto",
        speakerName: String? = "Ana",
        language: String = "es",
        glossary: [String] = ["deploy"],
        notes: [ContextItem] = []
    ) -> SummaryRequest {
        let speaker = Speaker(meetingID: meeting, label: "S1", displayName: speakerName)
        return SummaryRequest(
            meetingID: meeting,
            segments: [
                TranscriptSegment(
                    meetingID: meeting, speakerID: speaker.id, channel: .system,
                    text: text, startTime: 0, endTime: 3, isFinal: true)
            ],
            speakers: [speaker],
            recipe: .general,
            targetLanguage: language,
            glossary: glossary,
            contextItems: notes
        )
    }

    func testStableAndLanguageInsensitive() {
        let base = SummaryFingerprint.compute(request: request(), providerID: "fm")
        XCTAssertEqual(
            base, SummaryFingerprint.compute(request: request(), providerID: "fm"),
            "same material must fingerprint identically")
        XCTAssertEqual(
            base,
            SummaryFingerprint.compute(request: request(language: "en"), providerID: "fm"),
            "output language must NOT change the fingerprint — that's what makes the pivot possible"
        )
    }

    func testMaterialAndMethodChangesInvalidate() {
        let base = SummaryFingerprint.compute(request: request(), providerID: "fm")
        XCTAssertNotEqual(
            base,
            SummaryFingerprint.compute(request: request(text: "otro tema"), providerID: "fm"))
        XCTAssertNotEqual(
            base,
            SummaryFingerprint.compute(
                request: request(speakerName: "José"), providerID: "fm"),
            "renaming a speaker changes the attributions, so it must invalidate")
        XCTAssertNotEqual(
            base,
            SummaryFingerprint.compute(request: request(glossary: []), providerID: "fm"))
        XCTAssertNotEqual(
            base,
            SummaryFingerprint.compute(
                request: request(notes: [
                    ContextItem(meetingID: meeting, kind: .note, content: "clave", timestamp: 5)
                ]), providerID: "fm"))
        XCTAssertNotEqual(
            base, SummaryFingerprint.compute(request: request(), providerID: "api.x.com/gpt"))
    }
}

final class StructuredSummaryParseTests: XCTestCase {
    /// `parse` only ever sees markdown WE rendered, so the round trip
    /// through `markdown(recipe:)` is the whole contract — action items
    /// included (text + owner label split on the renderer's " — ").
    func testParseInvertsOurRenderer() {
        let original = StructuredSummary(
            overview: "El equipo acordó el plan.",
            sections: [
                .init(heading: "Decisiones", bullets: ["▸ rollout el viernes", "beta la próxima semana"]),
                .init(heading: "Preguntas abiertas", bullets: ["¿quién revisa el budget?"]),
            ],
            actionItems: [
                .init(text: "preparar rollout", owner: "S1"),
                .init(text: "avisar al equipo"),
            ])

        let parsed = StructuredSummary.parse(markdown: original.markdown(recipe: .general))
        XCTAssertEqual(parsed?.overview, "El equipo acordó el plan.")
        XCTAssertEqual(parsed?.sections, original.sections)
        XCTAssertEqual(parsed?.actionItems, original.actionItems)
    }

    func testParseRejectsShapelessText() {
        XCTAssertNil(StructuredSummary.parse(markdown: "   \n\n  "))
    }
}

final class TranslationPromptTests: XCTestCase {
    func testInstructionsFreezeStructureAndCarryLanguage() {
        let instructions = PromptFactory.translationInstructions(
            targetLanguage: "es", glossary: ["deploy"])
        XCTAssertTrue(instructions.contains("Spanish (español)"))
        XCTAssertTrue(instructions.contains("deploy"))
        XCTAssertTrue(instructions.contains("▸"))
        XCTAssertTrue(instructions.contains("no content added"))
    }

    func testPromptClosesWithTheLanguageOrder() {
        let prompt = PromptFactory.translationPrompt(
            markdown: "## Overview\n- hi", actionItems: "1. ship it", targetLanguage: "es")
        XCTAssertTrue(prompt.contains("## Overview"))
        XCTAssertTrue(prompt.contains("1. ship it"))
        XCTAssertTrue(prompt.hasSuffix("Spanish (español)."), "the language order closes the prompt (D18)")
    }
}

// MARK: - BYOK chat client (offline)

final class OpenAICompatibleChatClientTests: XCTestCase {
    func testRequestBodyIsOpenAICompatible() throws {
        let urlRequest = try OpenAICompatibleChatClient.urlRequest(
            endpoint: URL(string: "https://api.example.com/v1")!,
            model: "test-model", apiKey: "sk-123",
            system: "be terse", user: "¿var vs let?",
            temperature: 0.3, maxTokens: 400)

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sk-123")

        let body = try JSONSerialization.jsonObject(with: urlRequest.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["max_tokens"] as? Int, 400)
        let messages = body["messages"] as! [[String: String]]
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], "be terse")
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "¿var vs let?")
    }

    func testMaxTokensIsOmittedWhenNil() throws {
        let urlRequest = try OpenAICompatibleChatClient.urlRequest(
            endpoint: URL(string: "https://api.example.com/v1")!,
            model: "m", apiKey: "k",
            system: "s", user: "u", temperature: 0.3, maxTokens: nil)
        let body = try JSONSerialization.jsonObject(with: urlRequest.httpBody!) as! [String: Any]
        XCTAssertNil(body["max_tokens"])
    }

    func testParsesChatContentAndRejectsOtherShapes() throws {
        let payload = """
            {"choices": [{"message": {"content": "Hola."}}]}
            """
        XCTAssertEqual(
            try OpenAICompatibleChatClient.parseContent(Data(payload.utf8)), "Hola.")
        XCTAssertThrowsError(
            try OpenAICompatibleChatClient.parseContent(Data("{\"error\": \"nope\"}".utf8)))
    }

    func testProviderLabelIsTheHost() {
        let client = OpenAICompatibleChatClient(
            endpoint: URL(string: "http://localhost:11434/v1")!, model: "m", apiKey: "k")
        XCTAssertEqual(client.providerLabel, "localhost")
    }
}

// MARK: - BYOK settings (offline)

final class BYOKSettingsTests: XCTestCase {
    func testEndpointURLRejectsNonHTTPOrHostless() {
        XCTAssertNotNil(BYOKSettings.endpointURL(from: " https://api.openai.com/v1 "))
        XCTAssertNotNil(BYOKSettings.endpointURL(from: "http://localhost:11434/v1"))
        XCTAssertNil(BYOKSettings.endpointURL(from: "ftp://files.example.com"))
        XCTAssertNil(BYOKSettings.endpointURL(from: "api.openai.com/v1"))
        XCTAssertNil(BYOKSettings.endpointURL(from: ""))
    }

    func testClientRequiresEveryPiece() {
        XCTAssertNil(BYOKSettings.client(endpoint: "https://a.com/v1", model: "m", apiKey: nil))
        XCTAssertNil(BYOKSettings.client(endpoint: "https://a.com/v1", model: "m", apiKey: ""))
        XCTAssertNil(BYOKSettings.client(endpoint: "https://a.com/v1", model: "  ", apiKey: "k"))
        XCTAssertNil(BYOKSettings.client(endpoint: "nope", model: "m", apiKey: "k"))
        XCTAssertNotNil(BYOKSettings.client(endpoint: "https://a.com/v1", model: "m", apiKey: "k"))
    }

    /// The companion only ever gets a client behind the explicit opt-in
    /// (D8/D26) — configuration alone is not consent.
    func testCompanionClientRequiresTheExplicitOptIn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "byok-tests"))
        defer { defaults.removePersistentDomain(forName: "byok-tests") }
        defaults.set("https://a.com/v1", forKey: BYOKSettings.endpointKey)
        defaults.set("m", forKey: BYOKSettings.modelKey)

        defaults.set(false, forKey: BYOKSettings.companionEnabledKey)
        XCTAssertNil(BYOKSettings.companionClient(defaults: defaults, apiKey: "k"))

        defaults.set(true, forKey: BYOKSettings.companionEnabledKey)
        XCTAssertNotNil(BYOKSettings.companionClient(defaults: defaults, apiKey: "k"))
        // Opt-in without a key degrades to nil (on-device), never an error.
        XCTAssertNil(BYOKSettings.companionClient(defaults: defaults, apiKey: nil))
    }
}

// MARK: - Ollama first-class (M12)

final class OllamaServiceTests: XCTestCase {
    func testParsesTagsResponse() {
        let json = """
            {"models":[
              {"name":"gpt-oss:20b","size":13793000000,"details":{"parameter_size":"20.9B"}},
              {"name":"bare","size":1,"details":{}}
            ]}
            """
        let models = OllamaService.parseModels(Data(json.utf8))
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.first?.name, "gpt-oss:20b")
        XCTAssertEqual(models.first?.parameterSize, "20.9B")
        XCTAssertEqual(models.first?.bytes, 13_793_000_000)
        XCTAssertEqual(models.last?.parameterSize, "", "missing details degrade to empty")
    }

    func testEmptyOnGarbage() {
        XCTAssertTrue(OllamaService.parseModels(Data("not json".utf8)).isEmpty)
    }

    /// Real end-to-end against a running Ollama (`PORTAVOZ_OLLAMA_TESTS=1`,
    /// `ollama serve`, at least one non-OCR model). Verifies a 100% local
    /// summary comes back through the OpenAI-compatible path.
    func testRealOllamaSummarizes() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_OLLAMA_TESTS"] == "1",
            "set PORTAVOZ_OLLAMA_TESTS=1 to run")
        guard await OllamaService.isRunning() else { throw XCTSkip("Ollama not running") }
        let model: String
        if let env = ProcessInfo.processInfo.environment["PORTAVOZ_OLLAMA_MODEL"] {
            model = env
        } else if let first = (await OllamaService.models()).map(\.name)
            .first(where: { !$0.contains("ocr") })
        {
            model = first
        } else {
            throw XCTSkip("no usable Ollama model")
        }

        let meeting = MeetingID()
        let me = Speaker(meetingID: meeting, label: "Me", isMe: true)
        let ana = Speaker(meetingID: meeting, label: "S1", displayName: "Ana")
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
                line(ana, "I will prepare the rollout plan by Friday.", 5),
            ],
            speakers: [me, ana], recipe: .general, targetLanguage: "es", glossary: ["roadmap"])

        let draft = try await OllamaService.summaryProvider(model: model).summarize(request)
        XCTAssertFalse(draft.markdown.isEmpty, "a local Ollama summary must come back")
        XCTAssertEqual(draft.language, "es")
    }
}

// MARK: - BYOK summary provider (offline)

final class OpenAICompatibleProviderTests: XCTestCase {
    private let meeting = MeetingID()

    private func request(contextItems: [ContextItem] = []) -> SummaryRequest {
        SummaryRequest(
            meetingID: meeting,
            segments: [
                TranscriptSegment(
                    meetingID: meeting, channel: .system, text: "hola",
                    startTime: 0, endTime: 1)
            ],
            speakers: [],
            recipe: .general,
            targetLanguage: "es",
            glossary: ["deploy"],
            contextItems: contextItems
        )
    }

    func testPromptCarriesGlossarySchemaAndTranscript() {
        let prompt = OpenAICompatibleSummaryProvider.prompt(for: request())
        XCTAssertTrue(prompt.system.contains("deploy"))
        XCTAssertTrue(prompt.system.contains("JSON"))
        XCTAssertTrue(prompt.user.contains("hola"))
        XCTAssertFalse(prompt.user.contains("THE USER'S OWN NOTES"))
    }

    /// D28 parity: the cloud path weaves the user's notes exactly like
    /// on-device — a BYOK summary must never silently drop them.
    func testPromptWeavesUserNotes() {
        let prompt = OpenAICompatibleSummaryProvider.prompt(
            for: request(contextItems: [
                ContextItem(meetingID: meeting, kind: .note, content: "revisar budget Q3", timestamp: 65)
            ]))
        XCTAssertTrue(prompt.system.contains("▸"))
        XCTAssertTrue(prompt.user.contains("THE USER'S OWN NOTES"))
        XCTAssertTrue(prompt.user.contains("[01:05] revisar budget Q3"))
    }

    func testParsesFencedJSONResponses() throws {
        let content = "```json\n{\"overview\": \"ok\", \"sections\": [], \"actionItems\": []}\n```"
        let summary = try OpenAICompatibleSummaryProvider.parseStructured(content)
        XCTAssertEqual(summary.overview, "ok")
    }

    func testRejectsNonJSONContent() {
        XCTAssertThrowsError(
            try OpenAICompatibleSummaryProvider.parseStructured("I cannot help with that."))
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

final class NamingExcerptTests: XCTestCase {
    private let meetingID = MeetingID()

    private func makeSpeakers() -> (me: Speaker, s1: Speaker, s2: Speaker) {
        (
            Speaker(meetingID: meetingID, label: "Me", isMe: true),
            Speaker(meetingID: meetingID, label: "S1"),
            Speaker(meetingID: meetingID, label: "S2")
        )
    }

    private func segment(
        _ text: String, speaker: Speaker?, start: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID, speakerID: speaker?.id, channel: .system,
            text: text, startTime: start, endTime: start + 2)
    }

    func testTakesFirstSubstantialUtterancesPerSpeaker() {
        let (me, s1, s2) = makeSpeakers()
        var segments: [TranscriptSegment] = [
            segment("uh", speaker: s1, start: 0),  // too short — skipped
            segment("hi everyone, this is Daniel from the platform team", speaker: s1, start: 1),
        ]
        for index in 0..<10 {
            segments.append(
                segment(
                    "long filler utterance number \(index) about nothing at all",
                    speaker: s2, start: 10 + Double(index)))
        }
        let excerpt = NamingExcerpt.build(
            segments: segments, speakers: [me, s1, s2], perSpeaker: 3)

        XCTAssertTrue(excerpt.contains("this is Daniel"))
        // Only the first 3 of S2's utterances make it.
        XCTAssertTrue(excerpt.contains("number 0"))
        XCTAssertTrue(excerpt.contains("number 2"))
        XCTAssertFalse(excerpt.contains("number 3"))
    }

    func testIncludesLinesAddressingAttendeeCandidates() {
        let (me, s1, s2) = makeSpeakers()
        var segments: [TranscriptSegment] = []
        for index in 0..<5 {
            segments.append(
                segment(
                    "long filler utterance number \(index) about nothing at all",
                    speaker: s1, start: Double(index)))
        }
        // Short line late in the meeting, would never make the per-speaker cut.
        segments.append(segment("thanks Vishakha", speaker: s2, start: 300))

        let excerpt = NamingExcerpt.build(
            segments: segments, speakers: [me, s1, s2],
            attendeeCandidates: ["Vishakha Rao"])
        XCTAssertTrue(excerpt.contains("thanks Vishakha"))
    }

    func testRespectsBudget() {
        let (me, s1, _) = makeSpeakers()
        let segments = (0..<50).map {
            segment(String(repeating: "palabra ", count: 30), speaker: s1, start: Double($0))
        }
        let excerpt = NamingExcerpt.build(
            segments: segments, speakers: [me, s1], perSpeaker: 50, budget: 500)
        XCTAssertLessThanOrEqual(excerpt.count, 500)
    }

    func testChronologicalOrder() {
        let (me, s1, s2) = makeSpeakers()
        let segments = [
            segment("second speaker introduces themselves here properly", speaker: s2, start: 50),
            segment("first speaker introduces themselves here properly", speaker: s1, start: 5),
        ]
        let excerpt = NamingExcerpt.build(segments: segments, speakers: [me, s1, s2])
        let first = excerpt.range(of: "first speaker")
        let second = excerpt.range(of: "second speaker")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        if let first, let second {
            XCTAssertLessThan(first.lowerBound, second.lowerBound)
        }
    }
}

final class QuestionHeuristicTests: XCTestCase {
    func testDetectsEnglishAndSpanishQuestions() {
        XCTAssertTrue(QuestionHeuristic.looksLikeQuestion("What's the difference between var and let?"))
        XCTAssertTrue(QuestionHeuristic.looksLikeQuestion("¿cuál es la diferencia entre var y let?"))
        XCTAssertTrue(QuestionHeuristic.looksLikeQuestion("how do we deploy this to staging"))
        XCTAssertTrue(QuestionHeuristic.looksLikeQuestion("cómo manejamos el rollback en producción"))
        XCTAssertTrue(
            QuestionHeuristic.looksLikeQuestion(
                "so the question is, do we add some logs to check if we are skipping those messages?"))
    }

    func testRejectsStatementsAndNoise() {
        XCTAssertFalse(QuestionHeuristic.looksLikeQuestion("yes?"))  // too short
        XCTAssertFalse(QuestionHeuristic.looksLikeQuestion("we deployed the change yesterday"))
        XCTAssertFalse(QuestionHeuristic.looksLikeQuestion("gracias a todos, nos vemos mañana"))
        XCTAssertFalse(QuestionHeuristic.looksLikeQuestion(""))
    }

    // MARK: "Te preguntaron" (D26) — mention gate

    func testMentionsMatchesWholeWordsAcrossCaseAndAccents() {
        XCTAssertTrue(QuestionHeuristic.mentions("Johnny Young", in: "johnny, ¿qué opinas del rollout?"))
        XCTAssertTrue(QuestionHeuristic.mentions("José", in: "y tu, Jose, cuentanos del deploy"))
        XCTAssertTrue(QuestionHeuristic.mentions("Ana María López", in: "eso lo ve ana maría con el equipo"))
        XCTAssertTrue(QuestionHeuristic.mentions("Johnny Young", in: "Johnny: can you share the numbers"))
    }

    func testMentionsRejectsSubstringsAndNoise() {
        XCTAssertFalse(
            QuestionHeuristic.mentions("John Smith", in: "Johnny will take that one"),
            "\"John\" must not fire inside \"Johnny\"")
        XCTAssertFalse(QuestionHeuristic.mentions("Johnny Young", in: "the young engineers agreed"))
        XCTAssertFalse(QuestionHeuristic.mentions("", in: "anything at all"))
        XCTAssertFalse(QuestionHeuristic.mentions("Ana", in: ""))
    }

    @available(macOS 26.0, *)
    func testClassifierInstructionsCarryTheOwnerNameOnlyWhenKnown() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        let named = LiveCompanion.classifierInstructions(ownerName: "Johnny")
        XCTAssertTrue(named.contains("\"Johnny\""))
        XCTAssertTrue(named.contains("EXCEPTION"))

        let anonymous = LiveCompanion.classifierInstructions(ownerName: nil)
        XCTAssertFalse(anonymous.contains("EXCEPTION"))
        XCTAssertTrue(anonymous.contains("NEVER qualify"))
    }
}

final class NotesWeavingTests: XCTestCase {
    private let meetingID = MeetingID()

    private func note(_ content: String, at timestamp: TimeInterval) -> ContextItem {
        ContextItem(meetingID: meetingID, kind: .note, content: content, timestamp: timestamp)
    }

    func testNotesBlockFormatsTimestampedChronologically() {
        let block = PromptFactory.notesBlock([
            note("pricing concerns", at: 192),
            note("ask about the rollback plan", at: 65),
        ])
        XCTAssertEqual(block, "[01:05] ask about the rollback plan\n[03:12] pricing concerns")
    }

    func testNotesBlockClipsLongNotesAndRespectsBudget() {
        let long = String(repeating: "x", count: 500)
        let block = PromptFactory.notesBlock([note(long, at: 0)], perNoteLimit: 50, budget: 800)
        XCTAssertEqual(block, "[00:00] " + String(repeating: "x", count: 50))

        let many = (0..<100).map { note("nota número \($0) con contenido", at: Double($0)) }
        let bounded = PromptFactory.notesBlock(many, budget: 200)
        XCTAssertLessThanOrEqual(bounded.count, 200)
        XCTAssertTrue(bounded.hasPrefix("[00:00]"))
    }

    func testNotesBlockSkipsEmptyAndFlattensNewlines() {
        let block = PromptFactory.notesBlock([
            note("   ", at: 0),
            note("línea\ncon salto", at: 5),
        ])
        XCTAssertEqual(block, "[00:05] línea con salto")
    }

    func testSummaryPromptPutsNotesFirstAndLanguageLast() {
        let prompt = PromptFactory.summaryPrompt(
            transcriptOrNotes: "MATERIAL", targetLanguage: "es",
            userNotes: "[00:01] mi nota")
        let notesIndex = try! XCTUnwrap(prompt.range(of: "mi nota")).lowerBound
        let materialIndex = try! XCTUnwrap(prompt.range(of: "MATERIAL")).lowerBound
        XCTAssertLessThan(notesIndex, materialIndex)
        XCTAssertTrue(prompt.hasSuffix("including every heading and bullet."))
    }

    func testSummaryPromptWithoutNotesIsUnchanged() {
        let prompt = PromptFactory.summaryPrompt(
            transcriptOrNotes: "MATERIAL", targetLanguage: "en")
        XCTAssertFalse(prompt.contains("USER'S OWN NOTES"))
        XCTAssertTrue(prompt.hasPrefix("Here is the meeting material"))
    }

    func testInstructionsGainNotesBehaviorOnlyWithNotes()
    {
        let with = PromptFactory.summaryInstructions(
            recipe: .general, targetLanguage: "en", glossary: [], hasUserNotes: true)
        let without = PromptFactory.summaryInstructions(
            recipe: .general, targetLanguage: "en", glossary: [], hasUserNotes: false)
        XCTAssertTrue(with.contains("▸"))
        XCTAssertFalse(without.contains("▸"))
    }
}
