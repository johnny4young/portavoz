import Foundation
import XCTest
@testable import DiarizationKit
@testable import IntelligenceKit
@testable import ModelStoreKit
@testable import PortavozCore
@testable import TranscriptionKit

final class CoreTypesTests: XCTestCase {
    func testTranscriptSegmentRoundTripsThroughCodable() throws {
        let segment = TranscriptSegment(
            meetingID: MeetingID(),
            channel: .microphone,
            text: "Hola, soy Johnny",
            language: "es",
            startTime: 1.5,
            endTime: 3.2,
            confidence: 0.94,
            isFinal: true
        )
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        XCTAssertEqual(decoded.text, segment.text)
        XCTAssertEqual(decoded.channel, .microphone)
        XCTAssertEqual(decoded.language, "es")
        XCTAssertTrue(decoded.isFinal)
    }

    func testAudioChunkComputesDurationFromSamplesAndRate() {
        let chunk = AudioChunk(
            channel: .system,
            samples: [Float](repeating: 0, count: 48_000),
            sampleRate: 48_000,
            timestamp: 0
        )
        XCTAssertEqual(chunk.duration, 1.0)
    }

    func testChannelsCoverDualCapture() {
        // "Mine vs theirs" must be structural: both channels exist from v1.
        XCTAssertTrue(AudioChannel.allCases.contains(.microphone))
        XCTAssertTrue(AudioChannel.allCases.contains(.system))
    }

    func testLanguageCodeCanonicalizesBCP47PrimaryLanguage() {
        XCTAssertEqual(LanguageCode(" ES_CO ")?.identifier, "es")
        XCTAssertEqual(LanguageCode("en-US")?.identifier, "en")
        XCTAssertNil(LanguageCode("und"))
        XCTAssertNil(LanguageCode(""))
    }

    func testTranscriptPolicySeparatesAutomaticFromExplicitHint() {
        XCTAssertEqual(TranscriptLanguagePolicy(persistedValue: nil), .automatic)
        XCTAssertNil(TranscriptLanguagePolicy(persistedValue: "auto").languageHint)
        XCTAssertEqual(TranscriptLanguagePolicy.automatic.persistedValue, "auto")
        XCTAssertEqual(
            TranscriptLanguagePolicy(persistedValue: "es-CO").languageHint,
            "es")
    }

    func testSummaryPolicyFollowsSpeechOrUsesIndependentFixedLanguage() {
        let following = SummaryLanguagePolicy(persistedValue: nil)
        XCTAssertEqual(following.persistedValue, "spoken")
        XCTAssertEqual(
            following.resolve(spokenLanguage: "es-CO", fallbackLanguage: "en").identifier,
            "es")
        XCTAssertEqual(
            following.resolve(spokenLanguage: nil, fallbackLanguage: "es-MX").identifier,
            "es")

        let fixed = SummaryLanguagePolicy(persistedValue: "en")
        XCTAssertEqual(
            fixed.resolve(spokenLanguage: "es", fallbackLanguage: "es").identifier,
            "en")
    }

    func testSummaryDraftDecodesOlderSnapshotWithoutTypedEvidence() throws {
        let draft = SummaryDraft(
            meetingID: MeetingID(), recipeID: "general", language: "en",
            markdown: "Overview", actionItems: [])
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        json.removeValue(forKey: "claims")
        json.removeValue(forKey: "decisionEvidence")
        json.removeValue(forKey: "actionItemEvidence")

        let decoded = try JSONDecoder().decode(
            SummaryDraft.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.claims.isEmpty)
        XCTAssertTrue(decoded.decisionEvidence.isEmpty)
        XCTAssertTrue(decoded.actionItemEvidence.isEmpty)
    }

    func testSummaryDecisionEvidenceUsesTheSameRevisionFence() {
        let meetingID = MeetingID()
        let segment = TranscriptSegment(
            meetingID: meetingID, channel: .system, text: "Ship Friday",
            startTime: 3, endTime: 6)
        let decision = SummaryDecisionEvidence(
            sectionOrdinal: 1,
            bulletOrdinal: 0,
            sourceTranscriptRevision: 2,
            evidenceSegmentIDs: [segment.id])

        XCTAssertEqual(
            decision.resolveEvidence(currentTranscriptRevision: 2, segments: [segment]).status,
            .current)
        XCTAssertEqual(
            decision.resolveEvidence(currentTranscriptRevision: 3, segments: [segment]).status,
            .stale)
        XCTAssertEqual(
            decision.resolveEvidence(currentTranscriptRevision: 2, segments: []).status,
            .unavailable)
    }

    func testActionItemEvidenceUsesStableTaskIdentityAndRevisionFence() {
        let meetingID = MeetingID()
        let actionItemID = UUID()
        let segment = TranscriptSegment(
            meetingID: meetingID, channel: .system, text: "Ana owns the rollout",
            startTime: 3, endTime: 6)
        let evidence = SummaryActionItemEvidence(
            actionItemID: actionItemID,
            sourceTranscriptRevision: 2,
            evidenceSegmentIDs: [segment.id])

        XCTAssertEqual(evidence.actionItemID, actionItemID)
        XCTAssertEqual(
            evidence.resolveEvidence(currentTranscriptRevision: 2, segments: [segment]).status,
            .current)
        XCTAssertEqual(
            evidence.resolveEvidence(currentTranscriptRevision: 3, segments: [segment]).status,
            .stale)
        XCTAssertEqual(
            evidence.resolveEvidence(currentTranscriptRevision: 2, segments: []).status,
            .unavailable)
    }

    func testCompanionEvidenceSeparatesQuestionAndAnswerRoles() {
        let meetingID = MeetingID()
        let question = TranscriptSegment(
            meetingID: meetingID, channel: .system, text: "When is rollout?",
            startTime: 6, endTime: 8)
        let answer = TranscriptSegment(
            meetingID: meetingID, channel: .system, text: "Ship Friday",
            startTime: 3, endTime: 6)
        let cardID = UUID()
        let evidence = CompanionCardEvidence(
            cardID: cardID,
            sourceTranscriptRevision: 2,
            questionSegmentIDs: [question.id],
            answerSegmentIDs: [answer.id])

        XCTAssertEqual(evidence.cardID, cardID)
        XCTAssertEqual(
            evidence.resolveQuestion(
                currentTranscriptRevision: 2,
                segments: [question, answer]).segments.map(\.id),
            [question.id])
        XCTAssertEqual(
            evidence.resolveAnswer(
                currentTranscriptRevision: 2,
                segments: [question, answer])?.segments.map(\.id),
            [answer.id])
        XCTAssertEqual(
            evidence.resolveQuestion(
                currentTranscriptRevision: 3,
                segments: [question, answer]).status,
            .stale)
    }

    func testCompanionCardDecodesOlderValueWithoutEvidence() throws {
        let cardID = UUID()
        let json = """
            {
              "id": "\(cardID.uuidString)",
              "question": "When?",
              "answer": "Friday.",
              "kind": "context",
              "source": "on-device",
              "directed": false,
              "askedAt": 6
            }
            """

        let decoded = try JSONDecoder().decode(CompanionCard.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, cardID)
        XCTAssertNil(decoded.evidence)
    }

    func testBuiltInRecipesClassifyDecisionSectionsExplicitly() {
        XCTAssertEqual(Recipe.general.decisionSectionIndexes, [1])
        XCTAssertEqual(Recipe.planning.decisionSectionIndexes, [1])
        XCTAssertEqual(Recipe.oneOnOne.decisionSectionIndexes, [2])
        XCTAssertTrue(Recipe.standup.decisionSectionIndexes.isEmpty)
        XCTAssertTrue(Recipe.interview.decisionSectionIndexes.isEmpty)
        XCTAssertTrue(Recipe(
            id: "custom-decisions",
            displayName: "Custom",
            sections: ["Decisions"],
            instructions: "Capture decisions").decisionSectionIndexes.isEmpty)
    }

    func testSummaryClaimFailsClosedWhenRevisionOrEvidenceChanges() {
        let meetingID = MeetingID()
        let segment = TranscriptSegment(
            meetingID: meetingID, channel: .system, text: "Ship Friday",
            startTime: 3, endTime: 6)
        let claim = SummaryClaim(
            kind: .overview,
            sourceTranscriptRevision: 2,
            evidenceSegmentIDs: [segment.id])

        XCTAssertEqual(
            claim.resolveEvidence(currentTranscriptRevision: 2, segments: [segment]).status,
            .current)
        XCTAssertEqual(
            claim.resolveEvidence(currentTranscriptRevision: 3, segments: [segment]).status,
            .stale)
        XCTAssertEqual(
            claim.resolveEvidence(currentTranscriptRevision: 2, segments: []).status,
            .unavailable)
    }

    func testSummaryClaimFeedbackIsBoundedNormalizedAndBackwardCompatible() throws {
        let correction = try XCTUnwrap(
            SummaryClaimFeedback.correction("  The rollout is next Monday.  "))
        XCTAssertEqual(correction.kind, .correction)
        XCTAssertEqual(correction.correctionText, "The rollout is next Monday.")
        XCTAssertNil(SummaryClaimFeedback.correction(" \n "))
        XCTAssertNil(SummaryClaimFeedback.correction(
            String(repeating: "x", count: SummaryClaimFeedback.maximumCorrectionLength + 1)))

        let claim = SummaryClaim(
            kind: .overview,
            evidenceSegmentIDs: [UUID()])
        let data = try JSONEncoder().encode(claim)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("feedback"))
        XCTAssertNil(try JSONDecoder().decode(SummaryClaim.self, from: data).feedback)

        let reviewed = SummaryClaim(
            kind: .overview,
            evidenceSegmentIDs: [UUID()],
            feedback: correction)
        let decoded = try JSONDecoder().decode(
            SummaryClaim.self,
            from: JSONEncoder().encode(reviewed))
        XCTAssertEqual(decoded.feedback, correction)
    }

    func testMalformedSummaryClaimFeedbackFailsClosed() throws {
        let invalid = """
            {"kind":"unsupported","correctionText":"hidden correction"}
            """
        XCTAssertThrowsError(try JSONDecoder().decode(
            SummaryClaimFeedback.self,
            from: Data(invalid.utf8)))
    }
}

final class IntelligenceTypesTests: XCTestCase {
    func testGeneralRecipeHasAttributionAwareInstructions() {
        XCTAssertTrue(Recipe.general.sections.contains("Action Items"))
        XCTAssertTrue(Recipe.general.instructions.contains("Never invent"))
    }

    func testSummaryRequestDefaultsToEnglishWithEmptyGlossary() {
        let request = SummaryRequest(
            meetingID: MeetingID(),
            segments: [],
            speakers: [],
            recipe: .general
        )
        XCTAssertEqual(request.targetLanguage, "en")
        XCTAssertTrue(request.glossary.isEmpty)
    }
}

final class ModelRegistryTests: XCTestCase {
    func testEveryModelTaskIsRoutable() {
        XCTAssertEqual(ModelTask.allCases.count, 5)
        XCTAssertTrue(ModelTask.allCases.contains(.liveTranscription))
        XCTAssertTrue(ModelTask.allCases.contains(.finalTranscription))
    }
}

final class TitleTemplateTests: XCTestCase {
    private let sample: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 7
        components.hour = 10
        components.minute = 47
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    func testRendersAllTokens() {
        let title = TitleTemplate.render(
            "{date} {time} ({seq}) reunión", date: sample, sequence: 3)
        XCTAssertEqual(title, "2026-07-07 10.47 (03) reunión")
    }

    func testBlankTemplateFallsBackToDefault() {
        let title = TitleTemplate.render("   ", date: sample, sequence: 1)
        XCTAssertEqual(title, "2026-07-07 10.47 Meeting")
    }

    func testUnknownTokensPassThrough() {
        XCTAssertEqual(
            TitleTemplate.render("{foo} x", date: sample, sequence: 1), "{foo} x")
    }

    func testWeekdayUsesLocale() {
        let title = TitleTemplate.render(
            "{weekday}", date: sample, sequence: 1, locale: Locale(identifier: "es_CO"))
        XCTAssertEqual(title.lowercased(), "martes")
    }
}
