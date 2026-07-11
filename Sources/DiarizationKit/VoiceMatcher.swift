import Foundation

/// Pure matching of a meeting's speaker embeddings against the gallery of
/// remembered voices. Produces SUGGESTIONS only — the UI presents them as
/// chips and nothing is ever applied by itself (same contract as the
/// transcript-evidence name suggestions, D21).
public enum VoiceMatcher {
    /// Same yardstick as the diarizer's effective clustering distance
    /// (0.45 × FluidAudio's internal ×1.2): if the clusterer would call two
    /// windows the same voice inside a meeting, we allow the cross-meeting
    /// suggestion. Cross-meeting audio varies more (codec, room), so this
    /// leans permissive — acceptable because a match is only ever a chip
    /// the user can ignore. Pending field calibration.
    public static let maxCosineDistance: Float = 0.54

    public struct Match: Equatable, Sendable {
        public let voiceLabel: String
        public let name: String
        /// Cosine distance (lower = closer); shown in the chip's tooltip so
        /// the user sees the evidence, mirroring the transcript chips.
        public let distance: Float
    }

    /// Matches each unnamed speaker's embedding against the gallery.
    /// Each speaker gets at most its single closest gallery voice, and each
    /// gallery voice is suggested for at most one speaker (the closest) —
    /// two speakers in one meeting can't both be "Marta".
    public static func matches(
        speakers: [(voiceLabel: String, embedding: [Float])],
        gallery: [RememberedVoice],
        maxDistance: Float = maxCosineDistance
    ) -> [Match] {
        var candidates: [Match] = []
        for speaker in speakers {
            var best: (name: String, distance: Float)?
            for voice in gallery {
                guard let distance = cosineDistance(speaker.embedding, voice.embedding),
                    distance <= maxDistance
                else { continue }
                if best == nil || distance < best!.distance {
                    best = (voice.name, distance)
                }
            }
            if let best {
                candidates.append(
                    Match(voiceLabel: speaker.voiceLabel, name: best.name, distance: best.distance))
            }
        }
        // One suggestion per gallery voice: keep the closest speaker.
        var byName: [String: Match] = [:]
        for match in candidates {
            if let existing = byName[match.name], existing.distance <= match.distance { continue }
            byName[match.name] = match
        }
        return byName.values.sorted { $0.voiceLabel < $1.voiceLabel }
    }

    /// 1 − cosine similarity; nil when either vector is degenerate (zero
    /// norm or mismatched dimensions) — degenerate input must never match.
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return nil }
        return 1 - dot / (normA.squareRoot() * normB.squareRoot())
    }
}
