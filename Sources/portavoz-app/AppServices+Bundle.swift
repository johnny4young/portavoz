import Foundation
import IntegrationsKit
import PortavozCore
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
