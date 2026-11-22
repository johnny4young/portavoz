import Foundation
import PortavozCore
import StorageKit

public protocol TodayVoicesReading: Sendable {
    func meetingRows(startedIn interval: DateInterval) async throws -> [MeetingStore.LibraryMeetingRow]
    func people(matchingAliases aliases: [String]) async throws -> [String: [Person]]
}

extension MeetingStore: TodayVoicesReading {}

/// Today's talk time and day axis from the meetings started today and the
/// calendar's upcoming events, with invitees resolved to confirmed people.
public struct LoadTodayVoices: ApplicationUseCase {
    public struct Request: Sendable {
        public let now: Date
        public let events: [UpcomingEvent]
        /// Events past today whose invitees the page still draws, e.g. tomorrow's hero.
        public let later: [UpcomingEvent]
        public let calendar: Calendar

        public init(
            now: Date, events: [UpcomingEvent], later: [UpcomingEvent] = [], calendar: Calendar = .current
        ) {
            self.now = now
            self.events = events
            self.later = later
            self.calendar = calendar
        }
    }

    private let store: any TodayVoicesReading

    public init(store: any TodayVoicesReading) {
        self.store = store
    }

    public func execute(_ request: Request) async throws -> TodayVoices {
        let start = request.calendar.startOfDay(for: request.now)
        let end = request.calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let day = DateInterval(start: start, end: end)
        let today = request.events.filter { day.start <= $0.startDate && $0.startDate < day.end }
        let names = Array(Set((today + request.later).flatMap(\.attendees))).sorted()
        let meetings = try await store.meetingRows(startedIn: day)
        let people: [String: [Person]]
        do {
            people = names.isEmpty ? [:] : try await store.people(matchingAliases: names)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Unresolved invitees still show as names; talk time never needs them.
            people = [:]
        }
        return TodayVoices(
            day: day, now: request.now, meetings: meetings, events: request.events, later: request.later,
            people: people)
    }
}
