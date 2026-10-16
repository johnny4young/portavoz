import ApplicationKit
import Foundation
import PortavozCore
import Testing

@testable import portavoz_app

@MainActor
struct MeetingDetailMetadataChapterEligibilityTests {
    enum Reading: CaseIterable, Sendable {
        case raw, refined, replacement, split, merge, suppression, fallback, empty
    }

    @Test(arguments: Reading.allCases)
    func eligibilityMatchesOriginalGenerationOrder(_ reading: Reading) throws {
        let fixture = Fixture()
        let detail = fixture.review(reading)
        let presentation = MeetingDetailTranscriptPresentation(
            detail: detail, chapterTitles: [0: "A different label"])
        let legacy = detail.transcriptGenerationMaterial()
        let expected = presentation.current.rows.map { row in
            TranscriptSegment(
                id: row.id, meetingID: detail.meeting.id,
                speakerID: row.speakerID, channel: row.channel,
                text: row.text, language: row.language,
                startTime: row.startTime, endTime: row.endTime,
                confidence: row.confidence, isFinal: row.isFinal)
        }
        expectMatchingSegments(legacy.segments, expected)
        expectMatchingSegments(presentation.current.generationSegments(meetingID: detail.meeting.id), expected)
        #expect(legacy.sourceSegmentIDsByGeneratedID == Dictionary(
            uniqueKeysWithValues: presentation.current.rows.map { ($0.id, $0.sourceSegmentIDs) }))
        #expect(legacy.baseTranscriptRevision == detail.meeting.transcriptRevision)
        #expect(legacy.correctionRevision == detail.correctionRevision)
        let starts = Set(ChapterExtractor.chapters(from: legacy.segments).map(\.startTime))

        let displayed = Set(presentation.current.chapters.map(\.startTime))
        let titledVariants: [Set<TimeInterval>] = [[], starts, displayed, [130], [310]]
        for titled in titledVariants {
            var eligibility = MeetingDetailMetadataSuggestionState()
            let attempt = eligibility.begin(
                review: detail, content: presentation.current, titledChapterStarts: titled)
            #expect((attempt != nil) == (starts.isSubset(of: titled) == false))
            if let attempt {
                #expect(attempt.request.titledChapterStarts == titled)
                #expect(attempt.request.review.meeting.id == detail.meeting.id)
                #expect(attempt.request.review.correctionRevision == detail.correctionRevision)
                #expect(attempt.request.review.segments.map(\.id) == detail.segments.map(\.id))
                #expect(attempt.suggestsMeetingTitle == false)
                #expect(attempt.suggestsRecipe == false)
            }
        }
        if reading != .fallback {
            #expect(presentation.current.lineage.projection == .composed)
        }
        if reading == .fallback {
            #expect(presentation.current.lineage.projection == .accepted)
            // Accepted chapters precede canonical row sorting; generation
            // eligibility must NOT copy these displayed markers blindly.
            #expect(Set(presentation.current.chapters.map(\.startTime)) == [0, 130, 310])
            #expect(starts == [0, 310])
        }
    }

    @Test
    func authoritativeCoreAndTitlesKeepEligibilityCoherent() throws {
        let fixture = Fixture()
        let original = fixture.review(.raw)
        var state = MeetingDetailTranscriptPresentationState()
        state.receiveCore(original, resetChapterTitles: true)
        let first = try #require(state.presentation)
        let didMerge = state.mergeChapterTitles([0: "Friday"], detail: original)
        #expect(didMerge)
        let titled = try #require(state.presentation)
        #expect(titled !== first)
        expectMatchingSegments(
            titled.current.generationSegments(meetingID: original.meeting.id),
            first.current.generationSegments(meetingID: original.meeting.id))
        let didMergeAgain = state.mergeChapterTitles([0: "Friday"], detail: original)
        #expect(didMergeAgain == false)
        #expect(state.presentation === titled)

        let changed = fixture.review(.empty)
        #expect(changed.correctionRevision == original.correctionRevision)
        state.receiveCore(changed, resetChapterTitles: false)
        #expect(state.presentation !== titled)
        let empty = try #require(state.presentation)
        var eligibility = MeetingDetailMetadataSuggestionState()
        let emptyAttempt = eligibility.begin(
            review: changed, content: empty.current, titledChapterStarts: Set(state.chapterTitles.keys))
        #expect(emptyAttempt == nil)
        state.receiveCore(nil, resetChapterTitles: true)
        #expect(state.presentation == nil)
        #expect(state.chapterTitles.isEmpty)
    }
}

private extension MeetingDetailMetadataChapterEligibilityTests {
    func expectMatchingSegments(_ actual: [TranscriptSegment], _ expected: [TranscriptSegment]) {
        #expect(actual.count == expected.count)
        for (actual, expected) in zip(actual, expected) {
            #expect(actual.id == expected.id)
            #expect(actual.meetingID == expected.meetingID)
            #expect(actual.speakerID == expected.speakerID)
            #expect(actual.channel == expected.channel)
            #expect(actual.text == expected.text)
            #expect(actual.language == expected.language)
            #expect(actual.startTime == expected.startTime)
            #expect(actual.endTime == expected.endTime)
            #expect(actual.confidence == expected.confidence)
            #expect(actual.isFinal == expected.isFinal)
            #expect(actual.liveUpdateMode == expected.liveUpdateMode)
        }
    }

    struct Fixture {
        var meeting = Meeting(title: "Planning", startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let speakerID = SpeakerID()
        let ids = (0..<4).map { _ in UUID() }

        func review(_ reading: Reading) -> MeetingReviewReadModel {
            let segments = [
                segment(0, start: 0, end: 250), segment(1, start: 0, end: 2),
                segment(2, start: 130, end: 132), segment(3, start: 310, end: 314),
            ]
            let corrections: [TranscriptCorrectionEvent]
            switch reading {
            case .replacement:
                corrections = [edit(targets: [ids[2]], kind: .replaceText(text: "Viernes API", language: "es"))]
            case .split:
                corrections = [edit(targets: [ids[0]], kind: .split([
                    TranscriptCorrectionPart(text: "Primera parte", speakerID: speakerID,
                                             language: "es", startTime: 0, endTime: 125),
                    TranscriptCorrectionPart(text: "Second part", speakerID: speakerID,
                                             language: "en", startTime: 125, endTime: 250),
                ]))]
            case .merge:
                corrections = [edit(targets: [ids[2], ids[3]], kind: .merge(replacementText: nil, language: "es"))]
            case .suppression:
                corrections = [edit(targets: [ids[2]], kind: .suppress)]
            case .fallback:
                corrections = [edit(targets: [UUID()], kind: .suppress)]
            default:
                corrections = []
            }
            return MeetingReviewReadModel(
                core: MeetingReviewCore(
                    meeting: meeting, speakers: [], segments: reading == .empty ? [] : segments,
                    corrections: corrections, isRefinedTranscript: reading == .refined),
                summary: nil, companionCards: [], privacyReceipt: nil, processingJobs: [])
        }

        func segment(_ index: Int, start: TimeInterval, end: TimeInterval) -> TranscriptSegment {
            TranscriptSegment(
                id: ids[index], meetingID: meeting.id, speakerID: speakerID,
                channel: .system, text: "El viernes revisamos API \(index).", language: "es",
                startTime: start, endTime: end, confidence: 0.91, isFinal: true)
        }

        func edit(targets: [UUID], kind: TranscriptCorrectionKind) -> TranscriptCorrectionEvent {
            TranscriptCorrectionEvent(
                meetingID: meeting.id, baseTranscriptRevision: meeting.transcriptRevision,
                targetSegmentIDs: targets, kind: kind, sourceDeviceID: UUID(),
                createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        }
    }
}
