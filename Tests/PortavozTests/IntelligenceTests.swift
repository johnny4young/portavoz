import Foundation
import PortavozCore
import XCTest

@testable import IntegrationsKit
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
        XCTAssertTrue(instructions.contains("Decisions"))
        XCTAssertTrue(instructions.contains("decision-bearing bullet"))
        XCTAssertTrue(instructions.contains("exactly one structured section entry"))
        XCTAssertTrue(instructions.contains("every supported action item"))
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

    func testEvidenceFormatterMapsExactTagsAndRejectsUnknownReferences() {
        let segments = [
            TranscriptSegment(
                meetingID: meeting, channel: .system, text: "first",
                startTime: 0, endTime: 1),
            TranscriptSegment(
                meetingID: meeting, channel: .system, text: "second says [E1]",
                startTime: 2, endTime: 3)
        ]
        let material = TranscriptFormatter.formatWithEvidence(
            segments: segments, speakers: [])

        XCTAssertTrue(material.text.contains("[E1] [00:00]"))
        XCTAssertTrue(material.text.contains("[E2] [00:02]"))
        XCTAssertTrue(material.text.contains("second says [quoted-E1]"))
        XCTAssertEqual(
            TranscriptFormatter.resolveEvidenceTags(
                ["E2", "E99", "E2", "e1"],
                segmentIDsByTag: material.segmentIDsByTag),
            [segments[1].id])
        XCTAssertTrue(
            TranscriptFormatter.resolveEvidenceTags(
                ["E1"], segmentIDsByTag: material.segmentIDsByTag, limit: 0).isEmpty)
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

    func testDraftCreatesOnlyValidatedOverviewEvidence() {
        let first = TranscriptSegment(
            meetingID: meeting, channel: .system, text: "first",
            startTime: 0, endTime: 1)
        let second = TranscriptSegment(
            meetingID: meeting, channel: .system, text: "second",
            startTime: 2, endTime: 3)
        var cited = summary
        cited.overviewEvidence = ["E2", "E404", "E2"]
        let request = SummaryRequest(
            meetingID: meeting,
            segments: [first, second],
            speakers: [],
            recipe: .general)

        let draft = cited.draft(for: request)
        XCTAssertEqual(draft.claims.count, 1)
        XCTAssertEqual(draft.claims.first?.kind, .overview)
        XCTAssertEqual(draft.claims.first?.evidenceSegmentIDs, [second.id])
        XCTAssertTrue(cited.draft(for: request, includeEvidence: false).claims.isEmpty)
    }

    func testDraftCreatesPositionTypedDecisionEvidenceFromExactTags() throws {
        let first = TranscriptSegment(
            meetingID: meeting, channel: .system, text: "context",
            startTime: 0, endTime: 1)
        let second = TranscriptSegment(
            meetingID: meeting, channel: .system, text: "ship Friday",
            startTime: 2, endTime: 3)
        let cited = StructuredSummary(
            overview: "Overview",
            sections: [
                .init(heading: "Overview", bullets: ["Context"]),
                .init(
                    heading: "Decisions",
                    bullets: ["Ship Friday", "Keep local"],
                    bulletEvidence: [["E2", "E404", "E2"], []]),
                .init(heading: "Action Items", bullets: []),
                .init(heading: "Open Questions", bullets: ["Budget?"])
            ],
            actionItems: [])
        let request = SummaryRequest(
            meetingID: meeting,
            segments: [first, second],
            speakers: [],
            recipe: .general)

        let evidence = try XCTUnwrap(cited.draft(for: request).decisionEvidence.first)
        XCTAssertEqual(cited.draft(for: request).decisionEvidence.count, 1)
        XCTAssertEqual(evidence.sectionOrdinal, 1)
        XCTAssertEqual(evidence.bulletOrdinal, 0)
        XCTAssertEqual(evidence.evidenceSegmentIDs, [second.id])
        XCTAssertTrue(cited.draft(for: request, includeEvidence: false).decisionEvidence.isEmpty)
    }

    func testDecisionEvidenceFailsClosedWithoutAnExactRecipeShape() {
        let segment = TranscriptSegment(
            meetingID: meeting, channel: .system, text: "ship Friday",
            startTime: 0, endTime: 1)
        let malformed = StructuredSummary(
            overview: "Overview",
            sections: [
                .init(
                    heading: "Decisions",
                    bullets: ["Ship Friday"],
                    bulletEvidence: [["E1"]])
            ],
            actionItems: [])
        let general = SummaryRequest(
            meetingID: meeting, segments: [segment], speakers: [], recipe: .general)
        let custom = SummaryRequest(
            meetingID: meeting,
            segments: [segment],
            speakers: [],
            recipe: Recipe(
                id: "custom-decisions",
                displayName: "Custom",
                sections: ["Decisions"],
                instructions: "Capture decisions"))

        XCTAssertTrue(malformed.draft(for: general).decisionEvidence.isEmpty)
        XCTAssertTrue(malformed.draft(for: custom).decisionEvidence.isEmpty)
    }

    func testDraftCreatesIdentityTypedActionItemEvidenceFromExactTags() throws {
        let first = TranscriptSegment(
            meetingID: meeting, channel: .system, text: "context",
            startTime: 0, endTime: 1)
        let second = TranscriptSegment(
            meetingID: meeting, channel: .system, text: "Ana owns the rollout",
            startTime: 2, endTime: 3)
        let cited = StructuredSummary(
            overview: "Overview",
            sections: [],
            actionItems: [
                .init(
                    text: "Prepare rollout",
                    owner: "",
                    evidence: ["E2", "E404", "E2"])
            ])
        let request = SummaryRequest(
            meetingID: meeting,
            segments: [first, second],
            speakers: [],
            recipe: .general)

        let draft = cited.draft(for: request)
        let evidence = try XCTUnwrap(draft.actionItemEvidence.first)
        XCTAssertEqual(evidence.actionItemID, draft.actionItems[0].id)
        XCTAssertEqual(evidence.evidenceSegmentIDs, [second.id])
        XCTAssertTrue(cited.draft(for: request, includeEvidence: false).actionItemEvidence.isEmpty)
    }

    func testTranslationPreservesValidDecisionCoordinatesWithFreshIdentity() throws {
        let sourceID = UUID()
        let original = SummaryDecisionEvidence(
            sectionOrdinal: 0,
            bulletOrdinal: 1,
            sourceTranscriptRevision: 3,
            evidenceSegmentIDs: [sourceID])
        let pivot = SummaryDraft(
            meetingID: meeting,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "## Decisions\n- First\n- Second",
            actionItems: [],
            decisionEvidence: [original])
        let translatedSections = [
            StructuredSummary.Section(
                heading: "Decisiones",
                bullets: ["Primera", "Segunda"])
        ]

        let carried = try XCTUnwrap(StructuredSummary.translatedDecisionEvidence(
            from: pivot,
            into: translatedSections).first)
        XCTAssertNotEqual(carried.id, original.id)
        XCTAssertEqual(carried.sectionOrdinal, 0)
        XCTAssertEqual(carried.bulletOrdinal, 1)
        XCTAssertEqual(carried.sourceTranscriptRevision, 3)
        XCTAssertEqual(carried.evidenceSegmentIDs, [sourceID])
        XCTAssertTrue(StructuredSummary.translatedDecisionEvidence(
            from: pivot,
            into: [.init(heading: "Decisiones", bullets: ["Primera"])]).isEmpty)
    }

    func testTranslationRemapsActionItemEvidenceToFreshTaskIdentity() throws {
        let sourceID = UUID()
        let oldItem = ActionItem(text: "Prepare rollout")
        let original = SummaryActionItemEvidence(
            actionItemID: oldItem.id,
            sourceTranscriptRevision: 3,
            evidenceSegmentIDs: [sourceID])
        let pivot = SummaryDraft(
            meetingID: meeting,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Overview",
            actionItems: [oldItem],
            actionItemEvidence: [original])
        let translatedItem = ActionItem(text: "Preparar rollout")

        let carried = try XCTUnwrap(StructuredSummary.translatedActionItemEvidence(
            from: pivot,
            into: [translatedItem]).first)
        XCTAssertNotEqual(carried.id, original.id)
        XCTAssertEqual(carried.actionItemID, translatedItem.id)
        XCTAssertEqual(carried.sourceTranscriptRevision, 3)
        XCTAssertEqual(carried.evidenceSegmentIDs, [sourceID])
        XCTAssertTrue(StructuredSummary.translatedActionItemEvidence(
            from: pivot,
            into: []).isEmpty)
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

final class OpenAICompatibleChatCodecTests: XCTestCase {
    func testRequestBodyIsOpenAICompatible() throws {
        let urlRequest = try OpenAICompatibleChatCodec.urlRequest(
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
        let urlRequest = try OpenAICompatibleChatCodec.urlRequest(
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
            try OpenAICompatibleChatCodec.parseContent(Data(payload.utf8)), "Hola.")
        XCTAssertThrowsError(
            try OpenAICompatibleChatCodec.parseContent(Data("{\"error\": \"nope\"}".utf8)))
    }

    func testProviderLabelIsTheHost() {
        let client = OpenAICompatibleSummaryClient(
            endpoint: URL(string: "http://localhost:11434/v1")!,
            model: "m",
            apiKey: "k",
            gateway: TestDataEgressGateway())
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
        let gateway = TestDataEgressGateway()
        XCTAssertNil(BYOKSettings.client(
            endpoint: "https://a.com/v1", model: "m", apiKey: nil, gateway: gateway))
        XCTAssertNil(BYOKSettings.client(
            endpoint: "https://a.com/v1", model: "m", apiKey: "", gateway: gateway))
        XCTAssertNil(BYOKSettings.client(
            endpoint: "https://a.com/v1", model: "  ", apiKey: "k", gateway: gateway))
        XCTAssertNil(BYOKSettings.client(
            endpoint: "nope", model: "m", apiKey: "k", gateway: gateway))
        XCTAssertNotNil(BYOKSettings.client(
            endpoint: "https://a.com/v1", model: "m", apiKey: "k", gateway: gateway))
    }

    /// The companion only ever gets a client behind the explicit opt-in
    /// (D8/D26) — configuration alone is not consent.
    func testCompanionClientRequiresTheExplicitOptIn() {
        XCTAssertNil(BYOKSettings.companionClient(
            isEnabled: false,
            endpoint: "https://a.com/v1",
            model: "m",
            apiKey: "k",
            gateway: TestDataEgressGateway()))

        XCTAssertNotNil(BYOKSettings.companionClient(
            isEnabled: true,
            endpoint: "https://a.com/v1",
            model: "m",
            apiKey: "k",
            gateway: TestDataEgressGateway()))
        // Opt-in without a key degrades to nil (on-device), never an error.
        XCTAssertNil(BYOKSettings.companionClient(
            isEnabled: true,
            endpoint: "https://a.com/v1",
            model: "m",
            apiKey: nil,
            gateway: TestDataEgressGateway()))
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

        let draft = try await OllamaService.summaryProvider(
            model: model,
            gateway: URLSessionDataEgressGateway()).summarize(request)
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
        XCTAssertTrue(prompt.user.contains("[E1]"))
        XCTAssertTrue(prompt.system.contains("overviewEvidence"))
        XCTAssertTrue(prompt.system.contains("bulletEvidence"))
        XCTAssertTrue(prompt.system.contains("\"evidence\""))
        XCTAssertTrue(prompt.system.contains("one \"sections\" entry for every instructed recipe"))
        XCTAssertFalse(prompt.user.contains("THE USER'S OWN NOTES"))
    }

    /// D28 parity: the cloud path weaves the user's notes exactly like
    /// on-device — a BYOK summary must never silently drop them.
    func testPromptWeavesUserNotes() {
        let prompt = OpenAICompatibleSummaryProvider.prompt(
            for: request(contextItems: [
                ContextItem(
                    meetingID: meeting,
                    kind: .note,
                    content: "revisar [E1] budget Q3",
                    timestamp: 65)
            ]))
        XCTAssertTrue(prompt.system.contains("▸"))
        XCTAssertTrue(prompt.user.contains("THE USER'S OWN NOTES"))
        XCTAssertTrue(prompt.user.contains("[01:05] revisar [quoted-E1] budget Q3"))
    }

    func testParsesFencedJSONResponses() throws {
        let content = """
            ```json
            {"overview": "ok", "sections": [], "actionItems": [{"text": "ship", "owner": ""}]}
            ```
            """
        let summary = try OpenAICompatibleSummaryProvider.parseStructured(content)
        XCTAssertEqual(summary.overview, "ok")
        XCTAssertNil(summary.overviewEvidence, "older provider responses remain compatible")
        XCTAssertTrue(summary.sections.allSatisfy { $0.bulletEvidence == nil })
        XCTAssertNil(summary.actionItems.first?.evidence)
    }

    func testRejectsNonJSONContent() {
        XCTAssertThrowsError(
            try OpenAICompatibleSummaryProvider.parseStructured("I cannot help with that."))
    }

    /// Smaller local models (MLX Qwen3-4B) wrap the object in prose; the
    /// parser must recover the outermost braces instead of failing.
    func testParsesJSONWrappedInProse() throws {
        let content = """
            Aquí está el resumen solicitado:
            {"overview": "ok", "sections": [], "actionItems": []}
            Avísame si necesitas algo más.
            """
        let summary = try OpenAICompatibleSummaryProvider.parseStructured(content)
        XCTAssertEqual(summary.overview, "ok")
    }

    func testProseWrappedRecoveryStillRejectsBrokenJSON() {
        XCTAssertThrowsError(
            try OpenAICompatibleSummaryProvider.parseStructured("nope {\"overview\": } nope"))
    }

    /// Qwen3-4B writes Python-style \' escapes inside JSON strings — an
    /// invalid escape that fails the whole document unless repaired.
    func testRepairsPythonStyleSingleQuoteEscapes() throws {
        let content = #"{"overview": "usar \'Aurora Suite\' en vez de Kepler", "sections": [], "actionItems": []}"#
        let summary = try OpenAICompatibleSummaryProvider.parseStructured(content)
        XCTAssertEqual(summary.overview, "usar 'Aurora Suite' en vez de Kepler")
    }
}

final class LiveSummaryPolicyTests: XCTestCase {
    func testFirstRenderAlwaysShows() {
        XCTAssertTrue(LiveSummaryPolicy.shouldReplace(current: nil, candidate: "## Summary"))
        XCTAssertTrue(LiveSummaryPolicy.shouldReplace(current: "", candidate: "## Summary"))
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
        segments.append(segment("thanks Ilarion", speaker: s2, start: 300))

        let excerpt = NamingExcerpt.build(
            segments: segments, speakers: [me, s1, s2],
            attendeeCandidates: ["Ilarion Rao"])
        XCTAssertTrue(excerpt.contains("thanks Ilarion"))
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

/// A model that narrates action items as a section would duplicate the
/// canonical block (field evidence: MLX tripled the list on Jul 10).
final class ActionItemsDedupTests: XCTestCase {
    func testActionItemsShapedSectionIsSkippedInMarkdown() {
        let summary = StructuredSummary(
            overview: "ok",
            sections: [
                .init(heading: "Action Items", bullets: ["S1 committed to own the rollout"]),
                .init(heading: "Decisions", bullets: ["ship on Monday"])
            ],
            actionItems: [.init(text: "own the rollout", owner: "S1")])
        let markdown = summary.markdown(recipe: .general)
        XCTAssertEqual(markdown.components(separatedBy: "## Action Items").count, 2, "one block only")
        XCTAssertTrue(markdown.contains("## Decisions"))
    }

    func testSectionSurvivesWhenThereAreNoCanonicalItems() {
        let summary = StructuredSummary(
            overview: "ok",
            sections: [.init(heading: "Next steps", bullets: ["definir el plan"])],
            actionItems: [])
        XCTAssertTrue(summary.markdown(recipe: .general).contains("## Next steps"))
    }
}

/// Field case (Jul 10): 56 min → 530 chars and 0 action items from the
/// 3B. The chip must fire there and stay quiet for short meetings.
final class ThinSummaryPolicyTests: XCTestCase {
    func testCollapsedLongMeetingSummaryIsThin() {
        XCTAssertTrue(ThinSummaryPolicy.isThin(
            summaryCharacters: 530, actionItems: 0, meetingSeconds: 56 * 60))
    }

    func testLongMeetingWithoutActionItemsIsThin() {
        XCTAssertTrue(ThinSummaryPolicy.isThin(
            summaryCharacters: 2_000, actionItems: 0, meetingSeconds: 45 * 60))
    }

    func testShortMeetingsAreNeverThin() {
        XCTAssertFalse(ThinSummaryPolicy.isThin(
            summaryCharacters: 200, actionItems: 0, meetingSeconds: 10 * 60))
    }

    func testHealthyLongSummaryIsNotThin() {
        XCTAssertFalse(ThinSummaryPolicy.isThin(
            summaryCharacters: 4_000, actionItems: 8, meetingSeconds: 56 * 60))
    }

    func testMidLengthMeetingWithSubstanceIsNotThin() {
        XCTAssertFalse(ThinSummaryPolicy.isThin(
            summaryCharacters: 1_500, actionItems: 0, meetingSeconds: 25 * 60))
    }
}

final class CompanionAnswerTests: XCTestCase {
    func testExtractsOnlyUniqueInRangePassageCitationsInFirstUseOrder() {
        XCTAssertEqual(
            CompanionAnswer.citedPassageIndexes(
                "Sale el viernes [2], después de QA [1]. Confirmado [2] y no [9].",
                passageCount: 3),
            [1, 0])
        XCTAssertTrue(CompanionAnswer.citedPassageIndexes(
            "No citation here.",
            passageCount: 3).isEmpty)
    }

    func testKeepsARealAnswer() {
        XCTAssertEqual(
            CompanionAnswer.usable("The endpoint is the callback URL that Gian is posting."),
            "The endpoint is the callback URL that Gian is posting.")
    }

    func testStripsInlineCitationMarkers() {
        XCTAssertEqual(
            CompanionAnswer.usable("It takes about media hora de latencia [2]."),
            "It takes about media hora de latencia.")
    }

    func testStripsTrailingPassageReference() {
        // Field case: the RAG answerer verbalizes the citation.
        XCTAssertEqual(
            CompanionAnswer.usable(
                "Yes, the endpoint is the lab vision location API that they are no longer using. "
                    + "This is confirmed in passage 14."),
            "Yes, the endpoint is the lab vision location API that they are no longer using.")
    }

    func testKeepsPassageWordsThatArePartOfTheAnswer() {
        let answer = "Passage 3 of the migration plan owns the rollback procedure."
        XCTAssertEqual(CompanionAnswer.usable(answer), answer)
    }

    func testDropsEnglishHedges() {
        XCTAssertNil(CompanionAnswer.usable(
            "No, the VBD84 is not the one. The VBD84 is not mentioned in the context."))
        XCTAssertNil(CompanionAnswer.usable(
            "I apologize, but I cannot determine the answer. Could you provide more context?"))
    }

    func testDropsSpanishHedges() {
        XCTAssertNil(CompanionAnswer.usable("No se menciona el presupuesto en el contexto."))
        XCTAssertNil(CompanionAnswer.usable("Lo siento, no puedo determinar la respuesta."))
    }

    func testDropsEmptyOrCitationOnly() {
        XCTAssertNil(CompanionAnswer.usable(""))
        XCTAssertNil(CompanionAnswer.usable("   [3]   "))
    }
}
