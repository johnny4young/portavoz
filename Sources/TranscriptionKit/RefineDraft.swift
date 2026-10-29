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
    /// Detected versus decoded speech; nil when any channel was decoded
    /// without a voice detector.
    public let speechEvidence: SpeechDecodeEvidence?
    /// Successful provenance remains ephemeral until the user accepts this
    /// draft. Apply persists it atomically with the replacement transcript.
    public let generationRun: GenerationRun?

    public init(
        sourceTranscriptRevision: Int,
        language: String?, speakers: [Speaker], segments: [TranscriptSegment],
        oldSegmentCount: Int, oldSpeakerCount: Int,
        oldSpeechSeconds: TimeInterval, meetingSeconds: TimeInterval?,
        speechEvidence: SpeechDecodeEvidence? = nil,
        generationRun: GenerationRun? = nil
    ) {
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.language = language
        self.speakers = speakers
        self.segments = segments
        self.oldSegmentCount = oldSegmentCount
        self.oldSpeakerCount = oldSpeakerCount
        self.oldSpeechSeconds = oldSpeechSeconds
        self.meetingSeconds = meetingSeconds
        self.speechEvidence = speechEvidence
        self.generationRun = generationRun
    }

    public var newSpeechSeconds: TimeInterval {
        segments.reduce(0) { $0 + ($1.endTime - $1.startTime) }
    }
    /// A refined pass that covers well under the speech it should hold
    /// almost certainly failed — surfaced as a loud warning. With a voice
    /// detector, the question is whether Whisper decoded the speech it was
    /// given: the current transcript may be mostly silence hallucinations.
    /// Otherwise the current transcript's speech is the baseline, capped at
    /// the meeting's real duration (a corrupt transcript can double-count
    /// speech across channels: "108 min" in a 56-minute meeting).
    public var looksLossy: Bool {
        if let speechEvidence {
            return speechEvidence.decodedSeconds < speechEvidence.detectedSeconds * 0.5
        }
        var baseline = oldSpeechSeconds
        if let meetingSeconds { baseline = min(baseline, meetingSeconds) }
        return newSpeechSeconds < baseline * 0.5
    }
}

/// Speech a voice detector found and the speech Whisper decoded from it,
/// before transcript filters remove echo or boilerplate.
public struct SpeechDecodeEvidence: Equatable, Sendable {
    public let detectedSeconds: TimeInterval
    public let decodedSeconds: TimeInterval

    public init(detectedSeconds: TimeInterval, decodedSeconds: TimeInterval) {
        self.detectedSeconds = detectedSeconds
        self.decodedSeconds = decodedSeconds
    }

    /// Nil unless every channel was decoded behind a voice detector.
    public init?(_ transcriptions: [FileTranscription]) {
        var detected = 0.0
        var decoded = 0.0
        for transcription in transcriptions {
            guard let speech = transcription.detectedSpeechSeconds else { return nil }
            detected += speech
            decoded += transcription.segments.reduce(0) { $0 + $1.endTime - $1.startTime }
        }
        guard !transcriptions.isEmpty else { return nil }
        self.init(detectedSeconds: detected, decodedSeconds: decoded)
    }
}
