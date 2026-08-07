import AVFAudio
import Foundation

/// Decides whether a captured channel actually carries audio.
///
/// A digitally-silent channel must never be transcribed: fed pure silence,
/// the speech models invent text — a stray "Thank you." or foreign-script
/// gibberish (field bug jul 2026: a Bluetooth/AirPods output left the
/// system-audio channel at −∞ dBFS, and the transcript filled with
/// hallucinated Cyrillic). Detecting the silence lets callers skip it.
///
/// (Distinct from TranscriptionKit's `AudioLevel`, which peak-normalizes
/// samples for the quality pass.)
public enum AudioSilence {
    /// Peak absolute amplitude (0…1) of mono Float samples.
    public static func peak(of samples: [Float]) -> Float {
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        return peak
    }

    /// Whether the samples are effectively silent — peak below `floorDBFS`.
    /// The default −60 dBFS floor sits well under any real speech yet above
    /// the digital silence a dropped channel produces.
    public static func isSilent(_ samples: [Float], floorDBFS: Float = -60) -> Bool {
        let value = peak(of: samples)
        guard value > 0 else { return true }
        return 20 * log10(value) < floorDBFS
    }

    /// Reads an audio file in ~1 s blocks and reports whether it is
    /// effectively silent, stopping at the first block with real audio.
    /// Returns false when the file can't be read — better to transcribe a
    /// channel than to silently drop one we failed to inspect.
    ///
    /// "Can't be read" covers a failure *part way through*, not only a failure
    /// to open, and only reaching the end intact can conclude silence.
    ///
    /// Not for capture files: `CaptureFileWriter` uses CAF precisely so a
    /// killed recording stays fully readable, its data chunk sized to EOF, so
    /// its declared length never exceeds its readable bytes. The inputs that
    /// reach this branch arrive from elsewhere — `resolveExternalRefineAudio`
    /// hands over arbitrary user-imported files, and `MeetingAudioLayout`
    /// resolves compressed `.m4a` copies and legacy WAV. A file whose header
    /// promises more than the bytes deliver, or a read that fails because the
    /// recordings volume went away mid-scan, would otherwise be reported silent
    /// and have its channel dropped.
    public static func fileIsSilent(at url: URL, floorDBFS: Float = -60) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let format = file.processingFormat
        let blockSize: AVAudioFrameCount = 48_000
        guard file.length > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize)
        else { return false }
        let threshold = pow(10, floorDBFS / 20)
        while file.framePosition < file.length {
            buffer.frameLength = 0
            guard (try? file.read(into: buffer, frameCount: blockSize)) != nil else {
                // Inspection failed short of the end: fall back to keeping the
                // channel, exactly as an unopenable file does.
                return false
            }
            guard buffer.frameLength > 0 else { break }
            if peak(of: Downmix.mono(from: buffer)) >= threshold { return false }
        }
        return true
    }
}
