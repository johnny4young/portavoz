import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

extension AppServices {
    /// Creates the one presentation owner mounted by the resident menu-bar
    /// scene. AppServices remains composition; Store and EventKit stay private.
    func makeMenuBarModel() -> MenuBarModel {
        MenuBarModel(client: self)
    }
}

extension AppServices: MenuBarModelClient {
    func observeMenuBar() -> AsyncStream<MenuBarUpdate> {
        makeApplicationMenuBarStream(
            meetings: store.observeMenuBarMeetings(limit: 3),
            openItems: store.observeLibraryOpenItems(limit: 200))
    }

    func nextMenuBarEvent() -> UpcomingEvent? {
        guard !CalendarAttendeeSource.accessUndetermined else { return nil }
        return CalendarAttendeeSource().upcomingEvents().first
    }
}

private func makeApplicationMenuBarStream(
    meetings: AsyncThrowingStream<[Meeting], Error>,
    openItems: AsyncThrowingStream<[MeetingStore.OpenActionItem], Error>
) -> AsyncStream<MenuBarUpdate> {
    AsyncStream { continuation in
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await value in meetings {
                            continuation.yield(.meetings(value.map {
                                MenuBarMeeting(
                                    id: $0.id,
                                    title: $0.title,
                                    startedAt: $0.startedAt)
                            }))
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
                            continuation.yield(.pendingCounts(
                                Dictionary(grouping: value, by: \.meetingID)
                                    .mapValues(\.count)))
                        }
                    } catch is CancellationError {
                        // Parent cancellation ends the complete merged stream.
                    } catch {
                        continuation.yield(.failed(.pendingCounts))
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
