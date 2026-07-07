import Foundation

/// Locates a meeting's per-channel audio inside its `Audio/<uuid>/`
/// directory. Capture writes **CAF** (crash-safe: readable even after a
/// kill mid-recording); meetings recorded before jul 2026 have WAV — the
/// lookup prefers CAF and falls back, so old libraries keep working.
public enum MeetingAudioLayout {
    public static func channelFile(named channel: String, in directory: URL) -> URL? {
        for ext in ["caf", "wav"] {
            let url = directory.appendingPathComponent("\(channel).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
