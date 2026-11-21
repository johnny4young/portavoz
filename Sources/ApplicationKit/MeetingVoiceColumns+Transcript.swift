import Foundation
import PortavozCore
import StorageKit

extension VoiceColumns {
    /// One column per 2 pt of strip width, at most `maximumCount`.
    public static func count(forWidth width: Double) -> Int {
        guard width.isFinite, width > 0 else { return 0 }
        return max(1, Int(min(Double(maximumCount), width / 2)))
    }

    /// For small sizes: a column whose two neighbours agree takes their value.
    public static func calmed(_ columns: [UInt8]) -> [UInt8] {
        guard columns.count > 2 else { return columns }
        var result = columns
        for index in 1..<(columns.count - 1) where columns[index - 1] == columns[index + 1] {
            result[index] = columns[index - 1]
        }
        return result
    }
}

extension MeetingVoiceColumns {
    /// Bins a loaded transcript the way storage does, at any column count, so a
    /// strip drawn from the detail agrees with the library row.
    public init(
        speakers: [Speaker], segments: [TranscriptSegment], duration: TimeInterval, count: Int
    ) {
        let cast = Dictionary(speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let strip = VoiceColumns.strip(
            segments.compactMap { segment in
                segment.speakerID.flatMap { cast[$0] }.map {
                    (key: $0.id, start: segment.startTime, end: segment.endTime)
                }
            },
            duration: duration, count: count)
        self.init(
            duration: strip.duration,
            columns: strip.columns,
            voices: strip.voices.compactMap { voice in
                cast[voice.key].map {
                    Voice(
                        speakerID: $0.id, isMe: $0.isMe, label: $0.label, displayName: $0.displayName,
                        personID: $0.personID, talkSeconds: voice.talkSeconds, firstHeard: voice.firstHeard)
                }
            })
    }
}

extension VoiceCast {
    /// A stored strip's cast: voices arrive first heard first, so a hue clash
    /// goes to whoever spoke first, as in the detail.
    public init(columns: MeetingVoiceColumns) {
        self.init(
            members: columns.voices.map {
                Member(
                    key: Self.key($0.speakerID), isMe: $0.isMe, name: $0.displayName,
                    talkSeconds: $0.talkSeconds)
            },
            ordering: .talkShare)
    }

    /// The tint of each voice index a strip's columns point at.
    public func tints(for columns: MeetingVoiceColumns) -> [Tint] {
        columns.voices.map { $0.isMe ? .you : tint(for: $0.speakerID) }
    }
}

extension VoiceStripColumns {
    /// A stored strip with its cast and the tint of every voice index.
    public init(columns: MeetingVoiceColumns) {
        let cast = VoiceCast(columns: columns)
        self.init(columns: columns.columns, tints: cast.tints(for: columns), cast: cast, duration: columns.duration)
    }
}
