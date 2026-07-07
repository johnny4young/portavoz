import Foundation

/// Whisper's VAD gates on ABSOLUTE energy (WhisperKit EnergyVAD, threshold
/// 0.02 on float samples): a meeting played at low output volume sits under
/// it and "transcribes" to near-nothing — observed on a real 482 s meeting
/// that collapsed to 2 segments while a louder one sailed through. Peak
/// normalization makes the quality pass level-independent.
public enum AudioLevel {
    /// Scales samples so the peak sits at `target`. Capped at `maxGain` so
    /// a silent/noise-only file isn't amplified into garbage; a no-op when
    /// the audio is already healthy or truly empty.
    public static func normalizePeak(
        _ samples: inout [Float], target: Float = 0.9, maxGain: Float = 20
    ) {
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        guard peak > 0, peak < target else { return }
        let gain = min(target / peak, maxGain)
        guard gain > 1 else { return }
        for index in samples.indices {
            samples[index] *= gain
        }
    }
}

/// Formats the user's domain vocabulary as Whisper conditioning text.
///
/// Whisper prepends `promptTokens` as "previous context"
/// (`<|startofprev|>`), so a sentence that mentions the terms verbatim
/// biases decoding toward them — "LVGT" stops coming out as "LGBT" and the
/// summary stops hallucinating around the mishearing. Parakeet (live) has no
/// equivalent hook; the refine pass is where the vocabulary lands.
public enum VocabularyPrompt {
    public static func text(_ terms: [String]) -> String? {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        // Natural sentence, not a "Glossary:" list: Whisper conditions on
        // this as if it were prior transcript, and list-shaped context
        // derailed decoding on windows that didn't mention the terms.
        return "In this meeting we discussed " + cleaned.joined(separator: ", ") + "."
    }

    /// Parses the comma-separated form the Settings field and `--vocab` use.
    public static func parse(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
