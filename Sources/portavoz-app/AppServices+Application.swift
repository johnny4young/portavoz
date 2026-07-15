import ApplicationKit
import Foundation
import StorageKit

extension AppServices {
    /// ApplicationKit commands composed from the real local adapters.
    var meetingLifecycle: MeetingLifecycleUseCases { .init(store: store) }
    var meetingPurge: MeetingPurgeUseCases {
        .init(store: store, audioFiles: AppMeetingAudioFiles())
    }
}

/// Production filesystem adapter for permanent meeting-audio removal.
private struct AppMeetingAudioFiles: MeetingAudioFiles {
    func removeAudioDirectory(_ relativePath: String) throws {
        let directory = RecordingsLocation.shared.resolve(relativePath)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
