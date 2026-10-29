import Foundation
import PortavozCore

/// Separates loudspeaker echo from the user's own microphone speech using
/// measured audio, not words, so it holds when the two channels were
/// transcribed in different languages or with different errors.
public enum SpeakerEchoFilter {
    /// At least 90% of the segment's microphone energy is predicted echo.
    static let echoAttenuationDB = 10.0
    /// Share of an echo segment the system transcript must already cover for
    /// the echo to be redundant.
    static let coveredFraction = 0.5

    public struct Resolution: Sendable {
        /// The user's own microphone segments.
        public let microphone: [TranscriptSegment]
        /// Remote speech heard only through the microphone, moved to the
        /// system channel so the remote speaker owns it.
        public let recoveredSystem: [TranscriptSegment]
    }

    public static func resolve(
        microphone: [TranscriptSegment],
        system: [TranscriptSegment],
        profile: MicrophoneEchoProfile?
    ) -> Resolution {
        guard let profile else {
            return Resolution(microphone: microphone, recoveredSystem: [])
        }
        var kept: [TranscriptSegment] = []
        var recovered: [TranscriptSegment] = []
        for segment in microphone {
            guard let attenuation = profile.echoAttenuationDB(
                    from: segment.startTime, to: segment.endTime),
                attenuation >= echoAttenuationDB
            else {
                kept.append(segment)
                continue
            }
            if coverage(of: segment, by: system) < coveredFraction {
                recovered.append(TranscriptSegment(
                    id: segment.id,
                    meetingID: segment.meetingID,
                    channel: .system,
                    text: segment.text,
                    language: segment.language,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    confidence: segment.confidence,
                    isFinal: segment.isFinal))
            }
        }
        return Resolution(microphone: kept, recoveredSystem: recovered)
    }

    private static func coverage(
        of segment: TranscriptSegment,
        by system: [TranscriptSegment]
    ) -> Double {
        let duration = segment.endTime - segment.startTime
        guard duration > 0 else { return 1 }
        let overlaps = system.compactMap { other -> ClosedRange<TimeInterval>? in
            let start = max(segment.startTime, other.startTime)
            let end = min(segment.endTime, other.endTime)
            return start < end ? start...end : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var covered = 0.0
        var cursor = segment.startTime
        for overlap in overlaps where overlap.upperBound > cursor {
            covered += overlap.upperBound - max(cursor, overlap.lowerBound)
            cursor = overlap.upperBound
        }
        return covered / duration
    }
}
