import AudioPlaybackKit
import Foundation
import PortavozCore

/// The docked player's voice strip: who spoke when, binned on the scrubber's
/// axis so long silences stay as short as the timeline draws them.
public struct MeetingPlayerStrip: Sendable, Equatable {
    /// Columns per strip; drawing resamples them to the width.
    static let columnCount = VoiceColumns.maximumCount

    /// A cast voice with the diarization label the readout falls back to.
    public struct Voice: Sendable, Equatable {
        public let voice: VoiceCast.Voice
        public let label: String
    }

    private struct Turn: Sendable, Equatable {
        let voice: Voice
        let range: ClosedRange<TimeInterval>
    }

    public let strip: VoiceStripColumns
    /// Your voice's turns, for playing only them.
    public let myVoice: MeetingVoiceTable.Row?
    /// Turns by start, with the latest end so far, so a pause answers at once.
    private let turns: [Turn]
    private let latestEnds: [TimeInterval]
    private let indexes: [SpeakerID: UInt8]

    /// Draws attributed turns; without any, each loud waveform column takes
    /// you or the room by its louder channel, so the strip is never blank.
    public init(
        core: MeetingReviewCore, timeline: PlaybackTimeline, waveform: [MeetingWaveformBucket]
    ) {
        let labels = Dictionary(core.speakers.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        let rows = core.voiceTable.rows + core.voiceTable.others
        turns = rows
            .flatMap { row in
                let voice = Voice(voice: row.voice, label: labels[row.speakerID] ?? "")
                return row.turns.map { Turn(voice: voice, range: $0) }
            }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        latestEnds = turns.reduce(into: []) { ends, turn in
            ends.append(max(ends.last ?? -.infinity, turn.range.upperBound))
        }
        myVoice = rows.first { $0.voice.isMe }

        func onAxis(_ key: String, _ range: ClosedRange<TimeInterval>) -> (key: String, start: Double, end: Double) {
            (key, timeline.fraction(at: range.lowerBound), timeline.fraction(at: range.upperBound))
        }
        let entries: [(key: String, start: Double, end: Double)]
        let tint: (String) -> VoiceCast.Tint
        if rows.isEmpty {
            let slice = timeline.duration / Double(max(1, waveform.count))
            entries = slice > 0 ? waveform.enumerated().compactMap { index, bucket in
                guard bucket.amplitude >= Waveform.silenceThreshold else { return nil }
                let range = Double(index) * slice...Double(index + 1) * slice
                return onAxis(bucket.microphoneDominant ? "you" : "room", range)
            } : []
            tint = { $0 == "you" ? .you : .grey }
        } else {
            entries = rows.flatMap { row in row.turns.map { onAxis(VoiceCast.key(row.speakerID), $0) } }
            tint = core.voiceCast.tint(for:)
        }
        let binned = VoiceColumns.strip(entries, duration: 1, count: Self.columnCount)
        let keys = binned.voices.map(\.key)
        indexes = Dictionary(
            rows.compactMap { row in
                keys.firstIndex(of: VoiceCast.key(row.speakerID)).map { (row.speakerID, UInt8($0)) }
            },
            uniquingKeysWith: { first, _ in first })
        strip = VoiceStripColumns(
            columns: binned.columns,
            tints: keys.map(tint),
            cast: rows.isEmpty ? VoiceCast(members: [], ordering: .talkShare) : core.voiceCast,
            duration: timeline.duration)
    }

    /// Whoever holds the floor at `time`: the latest turn to start that has not ended.
    public func voice(at time: TimeInterval) -> Voice? {
        var low = 0
        var high = turns.count
        while low < high {
            let mid = (low + high) / 2
            if turns[mid].range.lowerBound <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0, latestEnds[low - 1] >= time else { return nil }
        return turns[..<low].last { $0.range.upperBound >= time }?.voice
    }

    /// The strip's column value for one voice, to draw it alone.
    public func voiceIndex(of speaker: SpeakerID) -> UInt8? {
        indexes[speaker]
    }
}
