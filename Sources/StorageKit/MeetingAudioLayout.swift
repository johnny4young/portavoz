import Foundation

/// Locates a meeting's per-channel audio inside its `Audio/<uuid>/`
/// directory. Capture writes **CAF** (crash-safe: readable even after a
/// kill mid-recording); meetings recorded before jul 2026 have WAV; a
/// meeting the user compressed has **m4a** (AAC, M11/D27). The lookup
/// prefers the compressed copy, then CAF, then WAV, before the formats
/// preserved by external-audio import.
public enum MeetingAudioLayout {
    /// Canonical channel extensions shared with meeting-bundle admission.
    /// Keep captured/compressed precedence; imported files retain their bytes.
    public static let channelExtensions = ["m4a", "caf", "wav", "mp3", "aac", "aiff", "aif", "m4b"]
    /// Only lossless channels may be compressed; re-encoding lossy audio
    /// would discard quality and the imported original.
    public static let losslessChannelExtensions: Set<String> = ["caf", "wav", "aiff", "aif"]

    public static func channelFile(named channel: String, in directory: URL) -> URL? {
        for ext in channelExtensions {
            let url = directory.appendingPathComponent("\(channel).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
