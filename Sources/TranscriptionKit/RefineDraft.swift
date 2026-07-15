import Foundation
import PortavozCore

/// A refine result awaiting the user's decision — never applied on its
/// own. The transcript it would replace stays untouched until "Apply".
public struct RefineDraft: Sendable {
    /// Revision used to produce this draft. Apply rejects it if a newer
    /// transcript landed while the user was reviewing the comparison.
    public let sourceTranscriptRevision: Int
    public let language: String?
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let oldSegmentCount: Int
    public let oldSpeakerCount: Int
    public let oldSpeechSeconds: TimeInterval
    /// Wall-clock length of the meeting, when known.
    public let meetingSeconds: TimeInterval?

    public init(
        sourceTranscriptRevision: Int,
        language: String?, speakers: [Speaker], segments: [TranscriptSegment],
        oldSegmentCount: Int, oldSpeakerCount: Int,
        oldSpeechSeconds: TimeInterval, meetingSeconds: TimeInterval?
    ) {
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.language = language
        self.speakers = speakers
        self.segments = segments
        self.oldSegmentCount = oldSegmentCount
        self.oldSpeakerCount = oldSpeakerCount
        self.oldSpeechSeconds = oldSpeechSeconds
        self.meetingSeconds = meetingSeconds
    }

    public var newSpeechSeconds: TimeInterval {
        segments.reduce(0) { $0 + ($1.endTime - $1.startTime) }
    }
    /// A refined pass that covers well under the current transcript's
    /// speech almost certainly failed — surfaced as a loud warning.
    /// The baseline is capped at the meeting's real duration: a corrupt
    /// transcript double-counts speech across channels (field case:
    /// "108 min of speech" in a 56-minute meeting), and a good refine
    /// must not be flagged for covering less than an impossible number.
    public var looksLossy: Bool {
        var baseline = oldSpeechSeconds
        if let meetingSeconds { baseline = min(baseline, meetingSeconds) }
        return newSpeechSeconds < baseline * 0.5
    }
}
