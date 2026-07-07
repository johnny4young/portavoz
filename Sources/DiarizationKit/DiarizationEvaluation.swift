import FluidAudio
import Foundation
import PortavozCore

/// Evaluation utilities for the M3 acceptance criterion (DER < 15%):
/// RTTM reference parsing and Diarization Error Rate against it.
public enum DiarizationEvaluation {
    /// The standard exclusion collar around reference boundaries (NIST).
    public static let standardCollar = 0.25

    public struct Score: Sendable {
        /// Total DER in [0, 1+] (miss + false alarm + confusion).
        public let der: Double
        public let miss: Double
        public let falseAlarm: Double
        public let confusion: Double
        /// Optimal hypothesis→reference label mapping used for scoring.
        public let mapping: [String: String]
    }

    /// Parses NIST RTTM: `SPEAKER <file> <chan> <tbeg> <tdur> … <speaker> …`.
    /// Lines that aren't SPEAKER records are ignored.
    public static func parseRTTM(_ text: String) -> [SpeakerTurn] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard
                fields.count >= 8,
                fields[0] == "SPEAKER",
                let start = Double(fields[3]),
                let duration = Double(fields[4])
            else { return nil }
            return SpeakerTurn(
                voiceLabel: String(fields[7]),
                startTime: start,
                endTime: start + duration
            )
        }
    }

    /// Frame-wise DER with optimal (Hungarian) label mapping, via
    /// FluidAudio's scorer.
    public static func score(
        reference: [SpeakerTurn],
        hypothesis: [SpeakerTurn],
        collar: Double = standardCollar
    ) -> Score {
        let result = DiarizationDER.compute(
            ref: reference.map {
                DERSpeakerSegment(speaker: $0.voiceLabel, start: $0.startTime, end: $0.endTime)
            },
            hyp: hypothesis.map {
                DERSpeakerSegment(speaker: $0.voiceLabel, start: $0.startTime, end: $0.endTime)
            },
            collar: collar
        )
        // FluidAudio reports der as a ratio but the components in seconds;
        // normalize everything to ratios of the reference speech.
        let total = max(result.totalRefSpeech, .ulpOfOne)
        return Score(
            der: result.der,
            miss: result.miss / total,
            falseAlarm: result.falseAlarm / total,
            confusion: result.confusion / total,
            mapping: result.mapping
        )
    }
}
