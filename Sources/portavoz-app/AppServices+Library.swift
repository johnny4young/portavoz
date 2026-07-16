import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

extension AppServices {
    /// Creates one presentation model per Library window. AppServices stays
    /// the composition root; query observation changes arrive in the next
    /// independent Strangler slice.
    func makeLibraryModel(
        searchDelay: Duration = .milliseconds(250)
    ) -> LibraryModel {
        LibraryModel(client: self, searchDelay: searchDelay)
    }
}

extension AppServices: LibraryModelClient {
    func loadLibraryMeetings() async throws -> [Meeting] {
        try await store.meetings()
    }

    func loadLibraryVoiceMixes(
        for meetingIDs: [MeetingID]
    ) async throws -> [MeetingID: [MeetingStore.VoiceMixSlice]] {
        try await store.voiceMixes(for: meetingIDs)
    }

    func loadLibraryOpenItems(limit: Int) async throws -> [MeetingStore.OpenActionItem] {
        try await store.openActionItems(limit: limit)
    }

    func loadLibraryTrash() async throws -> [MeetingStore.DeletedMeeting] {
        try await store.deletedMeetings()
    }

    func searchLibrary(_ query: String) async throws -> [SearchHit] {
        try await store.search(query)
    }

    func renameLibraryMeeting(_ meeting: Meeting) async throws {
        defer { libraryVersion += 1 }
        try await store.save(meeting)
    }

    func setLibraryActionItem(_ id: UUID, done: Bool) async throws {
        defer { libraryVersion += 1 }
        try await store.setActionItem(id, done: done)
    }

    func deleteLibraryMeeting(_ id: MeetingID) async throws {
        defer { libraryVersion += 1 }
        try await meetingLifecycle.delete(id)
    }

    func restoreLibraryMeeting(_ id: MeetingID) async throws {
        defer { libraryVersion += 1 }
        try await meetingLifecycle.restore(id)
    }

    func purgeLibraryMeeting(_ entry: MeetingStore.DeletedMeeting) async {
        await purgeMeeting(entry)
    }

    func importLibraryFile(
        _ url: URL,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> MeetingID {
        if url.pathExtension.lowercased() == MeetingBundle.fileExtension {
            return try await importBundle(from: url)
        }
        return try await importMeeting(from: url, progress: progress)
    }

    func libraryAgenda() -> LibraryModel.Agenda? {
        guard !ProcessInfo.processInfo.arguments.contains("-use-temp-store") else {
            return nil
        }
        let events = CalendarAttendeeSource().upcomingEvents()
        let startOfTomorrow = Calendar.current.startOfDay(
            for: Date().addingTimeInterval(24 * 3_600))
        return LibraryModel.Agenda(
            offerCalendar: CalendarAttendeeSource.accessUndetermined,
            today: events.filter { $0.startDate < startOfTomorrow },
            tomorrow: events.filter { $0.startDate >= startOfTomorrow })
    }

    func requestLibraryCalendarAccess() async {
        _ = await CalendarAttendeeSource.requestAccess()
    }

    func buildLibraryBrief(for event: UpcomingEvent) async -> MeetingBrief? {
        await MeetingBrief.build(for: event, store: store)
    }
}
