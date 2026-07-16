import ApplicationKit
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
    /// Optional audio and Companion cards travel as additive v1 fields.
    func importBundle(from url: URL) async throws -> MeetingID {
        let meetingID = try await importMeetingBundleUseCase.execute(
            ImportMeetingBundleRequest(sourceURL: url))
        libraryVersion += 1
        return meetingID
    }

    private var importMeetingBundleUseCase: ImportMeetingBundle {
        ImportMeetingBundle(
            documents: AppImportMeetingBundleDocuments(),
            files: AppImportMeetingBundleFiles(root: Self.audioRoot),
            store: store)
    }
}

private struct AppImportMeetingBundleDocuments: ImportMeetingBundleDocuments {
    func readRemappedBundle(
        from source: URL
    ) async throws -> ImportedMeetingBundleDocument {
        try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            let bundle = try MeetingBundle.decode(data).remappedForImport()
            let attachments = try (bundle.audioFiles ?? []).map {
                try ImportedMeetingBundleAttachment(
                    name: $0.name,
                    fileExtension: $0.fileExtension,
                    data: $0.data)
            }
            return try ImportedMeetingBundleDocument(
                meeting: bundle.meeting,
                speakers: bundle.speakers,
                segments: bundle.segments,
                summary: bundle.summary,
                contextItems: bundle.contextItems,
                companionCards: bundle.companionCards ?? [],
                attachments: attachments)
        }.value
    }
}

private struct AppImportMeetingBundleFiles: ImportMeetingBundleFiles {
    let root: URL

    func stageBundleAudio(
        _ attachments: [ImportedMeetingBundleAttachment],
        meetingID: MeetingID
    ) async throws -> ImportedMeetingBundleAudio {
        let root = root
        return try await Task.detached(priority: .utility) {
            let relativeDirectory = "Audio/\(meetingID.rawValue.uuidString)"
            let directory = root.appendingPathComponent(
                relativeDirectory,
                isDirectory: true)
            let files = FileManager.default
            guard !files.fileExists(atPath: directory.path) else {
                throw ImportMeetingBundleError.audioDirectoryAlreadyExists(
                    relativeDirectory)
            }
            do {
                try files.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true)
                for attachment in attachments {
                    let filename =
                        "\(attachment.channel.rawValue).\(attachment.fileExtension)"
                    try attachment.data.write(
                        to: directory.appendingPathComponent(filename),
                        options: .atomic)
                }
                return ImportedMeetingBundleAudio(
                    relativeDirectory: relativeDirectory)
            } catch {
                try? files.removeItem(at: directory)
                throw error
            }
        }.value
    }

    func discardBundleAudio(_ audio: ImportedMeetingBundleAudio) async throws {
        let directory = root.appendingPathComponent(
            audio.relativeDirectory,
            isDirectory: true)
        try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
        }.value
    }
}

extension AppServices {
    /// Permanently removes a trashed meeting: its stored rows (FTS cleans via
    /// triggers) AND its audio folder on disk.
    func purgeMeeting(_ entry: MeetingStore.DeletedMeeting) async {
        let request = PurgeMeetingRequest(
            meetingID: entry.meeting.id,
            audioDirectory: entry.meeting.audioDirectory)
        _ = try? await meetingPurge.purge(request)
        libraryVersion += 1
    }

    /// Empties tombstones older than 30 days (rows + audio) — called once
    /// at launch. The trash is a safety net, not an archive.
    func purgeExpiredTrash() async {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let attempted = (try? await meetingPurge.expired(cutoff)) ?? 0
        libraryVersion += attempted
    }
}
