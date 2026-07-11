import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit
import UniformTypeIdentifiers

extension UTType {
    /// The `.portavoz` interchange file (declared in Info.plist).
    static let meetingBundle = UTType(
        exportedAs: MeetingBundle.typeIdentifier, conformingTo: .json)
}

extension AppServices {
    /// Imports a `.portavoz` file as a NEW meeting (fresh IDs throughout —
    /// importing the same file twice yields two independent meetings).
    /// Audio does not travel in the v1 format, so the meeting arrives
    /// transcript-and-summary only.
    func importBundle(from url: URL) async throws -> MeetingID {
        let data = try Data(contentsOf: url)
        let bundle = try MeetingBundle.decode(data).remappedForImport()
        try await store.save(bundle.meeting)
        try await store.save(bundle.speakers)
        try await store.save(bundle.segments)
        if let summary = bundle.summary {
            try await store.saveSummary(summary)
        }
        if !bundle.contextItems.isEmpty {
            try await store.save(bundle.contextItems)
        }
        libraryVersion += 1
        return bundle.meeting.id
    }
}

extension AppServices {
    /// Permanently removes a trashed meeting: its rows (store.purge — FTS
    /// cleans via triggers) AND its audio folder on disk.
    func purgeMeeting(_ entry: MeetingStore.DeletedMeeting) async {
        if let relative = entry.meeting.audioDirectory {
            let dir = RecordingsLocation.shared.resolve(relative)
            try? FileManager.default.removeItem(at: dir)
        }
        try? await store.purge(entry.meeting.id)
        libraryVersion += 1
    }

    /// Empties tombstones older than 30 days (rows + audio) — called once
    /// at launch. The trash is a safety net, not an archive.
    func purgeExpiredTrash() async {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let expired = ((try? await store.deletedMeetings()) ?? [])
            .filter { $0.deletedAt < cutoff }
        for entry in expired {
            await purgeMeeting(entry)
        }
    }
}
