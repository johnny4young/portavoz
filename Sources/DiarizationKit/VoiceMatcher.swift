import Foundation

/// Pure matching of a meeting's speaker embeddings against the gallery of
/// remembered voices. Matches are suggestions; only one that clears the
/// stricter auto-assign bar may be applied without a tap, and stays undoable.
public enum VoiceMatcher {
    /// Same yardstick as the diarizer's effective clustering distance
    /// (0.45 × FluidAudio's internal ×1.2): if the clusterer would call two
    /// windows the same voice inside a meeting, we allow the cross-meeting
    /// suggestion. Cross-meeting audio varies more (codec, room), so this
    /// leans permissive — acceptable because a match is only ever a chip
    /// the user can ignore. Pending field calibration.
    public static let maxCosineDistance: Float = 0.54
    /// A second remembered voice this close behind makes the pick a coin flip.
    public static let minimumMargin: Float = 0.05
    /// Auto-assign bar: close, clearly ahead of any other name, and judged on
    /// enough speech that one noisy window cannot carry it.
    public static let autoAssignMaxDistance: Float = 0.35
    public static let autoAssignMinimumMargin: Float = 0.10
    public static let autoAssignMinimumSpeechSeconds: Double = 10

    /// True when a match is strong enough to name the speaker without a tap.
    /// With a single remembered name there is no runner-up to confuse it with.
    public static func isAutoAssignable(
        distance: Float, runnerUpDistance: Float?, speechSeconds: Double
    ) -> Bool {
        guard distance <= autoAssignMaxDistance,
              speechSeconds >= autoAssignMinimumSpeechSeconds
        else { return false }
        guard let runnerUpDistance else { return true }
        return runnerUpDistance - distance >= autoAssignMinimumMargin
    }

    public struct Match: Equatable, Sendable {
        public let voiceLabel: String
        public let name: String
        /// Cosine distance (lower = closer); shown in the chip's tooltip so
        /// the user sees the evidence, mirroring the transcript chips.
        public let distance: Float
        /// Distance to the closest other remembered name; nil with one name.
        public let runnerUpDistance: Float?

        public init(voiceLabel: String, name: String, distance: Float, runnerUpDistance: Float? = nil) {
            self.voiceLabel = voiceLabel
            self.name = name
            self.distance = distance
            self.runnerUpDistance = runnerUpDistance
        }
    }

    /// Matches each unnamed speaker's embedding against the gallery.
    /// Each speaker gets at most its single closest gallery voice, and each
    /// gallery voice is suggested for at most one speaker (the closest) —
    /// two speakers in one meeting can't both be "Marta". A speaker whose
    /// closest name leads the next one by less than `minimumMargin` gets none.
    public static func matches(
        speakers: [(voiceLabel: String, embedding: [Float])],
        gallery: [RememberedVoice],
        maxDistance: Float = maxCosineDistance,
        minimumMargin: Float = minimumMargin
    ) -> [Match] {
        var candidates: [Match] = []
        for speaker in speakers {
            var closestByName: [String: Float] = [:]
            for voice in gallery {
                guard let distance = cosineDistance(speaker.embedding, voice.embedding) else { continue }
                closestByName[voice.name] = min(distance, closestByName[voice.name] ?? .infinity)
            }
            let ranked = closestByName.sorted { $0.value < $1.value }
            guard let best = ranked.first, best.value <= maxDistance else { continue }
            let runnerUp = ranked.dropFirst().first?.value
            if let runnerUp, runnerUp - best.value < minimumMargin { continue }
            candidates.append(Match(
                voiceLabel: speaker.voiceLabel, name: best.key,
                distance: best.value, runnerUpDistance: runnerUp))
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
