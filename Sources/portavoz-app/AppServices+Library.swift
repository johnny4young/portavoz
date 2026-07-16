import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

extension AppServices {
    /// Creates one presentation model per Library window. AppServices stays
    /// the composition root while StorageKit observation stays private.
    func makeLibraryModel(
        searchDelay: Duration = .milliseconds(250)
    ) -> LibraryModel {
        LibraryModel(client: self, searchDelay: searchDelay)
    }
}

extension AppServices: LibraryModelClient {
    func observeLibrary() -> AsyncStream<LibraryUpdate> {
        makeApplicationLibraryStream(
            meetings: store.observeLibraryMeetings(),
            openItems: store.observeLibraryOpenItems(),
            trash: store.observeLibraryTrash())
    }

    func observeLibrarySearch(
        _ query: String
    ) -> AsyncThrowingStream<[LibrarySearchHit], Error> {
        mapStream(store.observeLibrarySearch(query)) { hits in
            hits.map(makeApplicationSearchHit)
        }
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

    func purgeLibraryMeeting(_ entry: LibraryTrashItem) async {
        await purgeMeeting(
            meetingID: entry.meeting.id,
            audioDirectory: entry.meeting.audioDirectory)
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

private func makeApplicationLibraryStream(
    meetings: AsyncThrowingStream<MeetingStore.LibraryMeetingRows, Error>,
    openItems: AsyncThrowingStream<[MeetingStore.OpenActionItem], Error>,
    trash: AsyncThrowingStream<[MeetingStore.DeletedMeeting], Error>
) -> AsyncStream<LibraryUpdate> {
    AsyncStream { continuation in
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await value in meetings {
                            continuation.yield(.meetings(
                                makeApplicationMeetingRows(value.rows),
                                failures: value.failures))
                        }
                    } catch is CancellationError {
                        // Parent cancellation ends the complete merged stream.
                    } catch {
                        continuation.yield(.failed(.meetings))
                    }
                }
                group.addTask {
                    do {
                        for try await value in openItems {
                            continuation.yield(.openItems(
                                value.map(makeApplicationOpenItem)))
                        }
                    } catch is CancellationError {
                        // Parent cancellation ends the complete merged stream.
                    } catch {
                        continuation.yield(.failed(.openItems))
                    }
                }
                group.addTask {
                    do {
                        for try await value in trash {
                            continuation.yield(.trash(
                                value.map(makeApplicationTrashItem)))
                        }
                    } catch is CancellationError {
                        // Parent cancellation ends the complete merged stream.
                    } catch {
                        continuation.yield(.failed(.trash))
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func makeApplicationMeetingRows(
    _ rows: [MeetingStore.LibraryMeetingRow]
) -> [LibraryMeetingRow] {
    rows.map { row in
        LibraryMeetingRow(
            meeting: row.meeting,
            voiceMix: row.voiceMix.map {
                LibraryVoiceMixSlice(
                    isMe: $0.isMe,
                    displayName: $0.displayName,
                    fraction: $0.fraction,
                    order: $0.order)
            })
    }
}

private func makeApplicationOpenItem(
    _ item: MeetingStore.OpenActionItem
) -> LibraryOpenItem {
    LibraryOpenItem(
        meetingID: item.meetingID,
        meetingTitle: item.meetingTitle,
        item: item.item)
}

private func makeApplicationTrashItem(
    _ item: MeetingStore.DeletedMeeting
) -> LibraryTrashItem {
    LibraryTrashItem(meeting: item.meeting, deletedAt: item.deletedAt)
}

private func makeApplicationSearchHit(_ hit: SearchHit) -> LibrarySearchHit {
    LibrarySearchHit(
        meetingID: hit.meetingID,
        meetingTitle: hit.meetingTitle,
        segmentID: hit.segmentID,
        snippet: hit.snippet,
        startTime: hit.startTime)
}

private func mapStream<Input: Sendable, Output: Sendable>(
    _ source: AsyncThrowingStream<Input, Error>,
    transform: @escaping @Sendable (Input) -> Output
) -> AsyncThrowingStream<Output, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let task = Task {
            do {
                for try await value in source {
                    continuation.yield(transform(value))
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
