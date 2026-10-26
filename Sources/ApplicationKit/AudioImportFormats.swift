import StorageKit

/// Imports admit exactly the formats that playback, Refine and export can locate.
public enum AudioImportFormats {
    public static let fileExtensions = MeetingAudioLayout.channelExtensions

    public static func admits(_ fileExtension: String) -> Bool {
        fileExtensions.contains(fileExtension.lowercased())
    }
}
