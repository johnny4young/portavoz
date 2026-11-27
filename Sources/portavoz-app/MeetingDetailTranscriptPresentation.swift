import ApplicationKit
import Foundation
import PortavozCore

/// One immutable reading/editor pair for an authoritative core and chapter
/// title set. Reference identity lets the route retain this work across
/// unrelated review updates without comparing every transcript row.
final class MeetingDetailTranscriptPresentation: Sendable {
    let current: MeetingTranscriptContent
    let structure: MeetingTranscriptStructureProjection

    init(detail: MeetingReviewReadModel, chapterTitles: [TimeInterval: String]) {
        // Keep the application's full composer, including its accepted fallback
        // and distinct accepted/composed lineage even with no active edits.
        let readings = detail.transcriptReadings(chapterTitles: chapterTitles)
        current = readings.current
        structure = detail.transcriptStructureProjection(current: readings.current, accepted: readings.accepted)
    }
}

/// Route-local input owner. Optional review sections never enter these
/// boundaries; every core delivery and changed title set does.
struct MeetingDetailTranscriptPresentationState {
    private(set) var chapterTitles: [TimeInterval: String] = [:]
    private(set) var presentation: MeetingDetailTranscriptPresentation?
    /// Everything the margin shows beside a line, keyed by that row.
    private(set) var marginNotes = MeetingMarginNotes.empty
    /// Voice matches without a shown line; the People tab lists them.
    private(set) var unplacedVoiceMatches: [MeetingVoiceSuggestion] = []
    private var reviewedNotes = MeetingMarginNotes.empty
    private var voiceMatches: [MeetingVoiceSuggestion] = []
    private var speakers: [Speaker] = []

    /// A core rebuilds the reading; reviews and summaries arrive outside it,
    /// so every update re-anchors the margin notes.
    mutating func receive(_ detail: MeetingReviewReadModel?, isCore: Bool, resetChapterTitles: Bool) {
        if isCore {
            if resetChapterTitles { chapterTitles = [:] }
            presentation = detail.map {
                MeetingDetailTranscriptPresentation(detail: $0, chapterTitles: chapterTitles)
            }
        }
        reviewedNotes = presentation.flatMap { detail?.marginNotes(in: $0.current) } ?? .empty
        speakers = detail?.speakers ?? []
        placeVoiceMatches()
    }

    /// Voice matches change without a review update, so they join here.
    mutating func receive(voiceMatches matches: [MeetingVoiceSuggestion]) {
        guard matches != voiceMatches else { return }
        voiceMatches = matches
        placeVoiceMatches()
    }

    private mutating func placeVoiceMatches() {
        guard let content = presentation?.current else {
            (marginNotes, unplacedVoiceMatches) = (reviewedNotes, voiceMatches)
            return
        }
        (marginNotes, unplacedVoiceMatches) = reviewedNotes.addingVoiceMatches(
            voiceMatches, speakers: speakers, in: content)
    }

    @discardableResult
    mutating func mergeChapterTitles(
        _ incoming: [TimeInterval: String], detail: MeetingReviewReadModel?
    ) -> Bool {
        var merged = chapterTitles
        merged.merge(incoming) { _, new in new }
        guard merged != chapterTitles else { return false }
        let next = detail.map {
            MeetingDetailTranscriptPresentation(detail: $0, chapterTitles: merged)
        }
        chapterTitles = merged
        presentation = next
        return true
    }
}

extension MeetingReviewUpdate {
    /// A core delivery carries the transcript; other updates carry reviews.
    var isCore: Bool {
        if case .core = self { return true }
        return false
    }
}
