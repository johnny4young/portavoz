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

    mutating func receiveCore(_ detail: MeetingReviewReadModel?, resetChapterTitles: Bool) {
        if resetChapterTitles { chapterTitles = [:] }
        presentation = detail.map {
            MeetingDetailTranscriptPresentation(detail: $0, chapterTitles: chapterTitles)
        }
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
