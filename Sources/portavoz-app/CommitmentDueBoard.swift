import ApplicationKit
import Foundation
import PortavozCore

/// Radar's "Commitments by due date": open confirmed commitments by due date
/// and suggestions put off with Review later on the day they come back.
struct CommitmentDueBoard: Equatable {
    enum Column: Hashable {
        case overdue
        case today
        /// A day after today and before next week, as its start of day.
        case day(Date)
        case nextWeek
        case later
    }

    /// What a chip opens.
    enum Target: Equatable {
        case commitment(CommitmentID)
        case meeting(MeetingID, at: TimeInterval?)
    }

    struct Chip: Identifiable, Equatable {
        let id: UUID
        let owner: String?
        let task: String
        let tint: VoiceCast.Tint
        let target: Target

        var isConfirmed: Bool {
            if case .commitment = target { return true }
            return false
        }
    }

    struct Lane: Identifiable, Equatable {
        let column: Column
        let chips: [Chip]
        var id: Column { column }
    }

    static let empty = CommitmentDueBoard(lanes: [])

    let lanes: [Lane]

    var isEmpty: Bool { lanes.allSatisfy(\.chips.isEmpty) }

    init(lanes: [Lane]) {
        self.lanes = lanes
    }

    /// Overdue, Today and Next week always show; a day or Later only with work in it.
    init(
        confirmed: [CommitmentRadarItem],
        upcoming: [CommitmentReviewQueueItem],
        now: Date,
        calendar: Calendar
    ) {
        let entries = confirmed.compactMap(Entry.init(confirmed:))
            + upcoming.compactMap(Entry.init(suggestion:))
        let cast = Self.cast(entries)
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let nextWeekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: week.end)
        else {
            self.init(lanes: [])
            return
        }
        func column(_ date: Date) -> Column {
            if date < today { return .overdue }
            if date < tomorrow { return .today }
            if date < week.end { return .day(calendar.startOfDay(for: date)) }
            return date < nextWeekEnd ? .nextWeek : .later
        }
        // Earliest first; on the same instant, confirmed work before a suggestion (sort is stable).
        let sorted = entries.sorted { ($0.date, $0.isSuggestion) < ($1.date, $1.isSuggestion) }
        let byColumn = Dictionary(grouping: sorted) { column($0.date) }
        let days = byColumn.keys.compactMap { column -> Date? in
            if case .day(let day) = column { return day }
            return nil
        }.sorted()
        let columns: [Column] = [.overdue, .today] + days.map(Column.day) + [.nextWeek]
            + (byColumn[.later] == nil ? [] : [.later])
        self.init(lanes: columns.map { column in
            Lane(column: column, chips: (byColumn[column] ?? []).map { $0.chip(cast) })
        })
    }

    /// Owners with the most work on the board take the five hues; the rest are
    /// grey. The cast ranks by talk, so a chip count stands in for seconds.
    private static func cast(_ entries: [Entry]) -> VoiceCast {
        var order: [String] = []
        var members: [String: VoiceCast.Member] = [:]
        for entry in entries {
            guard let owner = entry.owner else { continue }
            let count = members[owner.key]?.talkSeconds ?? 0
            if count == 0 { order.append(owner.key) }
            members[owner.key] = VoiceCast.Member(
                key: owner.key, isMe: owner.isMe, name: owner.name, talkSeconds: count + 1)
        }
        return VoiceCast(members: order.compactMap { members[$0] }, ordering: .talkShare)
    }
}

private struct Entry {
    struct Owner {
        let key: String
        let isMe: Bool
        let name: String
    }

    let id: UUID
    let date: Date
    let owner: Owner?
    let task: String
    let target: CommitmentDueBoard.Target

    var isSuggestion: Int {
        if case .meeting = target { return 1 }
        return 0
    }

    init?(confirmed item: CommitmentRadarItem) {
        guard item.commitment.status == .confirmed, let dueAt = item.commitment.dueAt else { return nil }
        id = item.id.rawValue
        date = dueAt
        task = item.commitment.title
        target = .commitment(item.id)
        switch item.commitment.assignee {
        case .me:
            owner = Owner(key: TodayVoices.Identity.me.key, isMe: true, name: L10n.text("You"))
        case .person(let personID):
            owner = VoiceCast.name(item.assigneeDisplayName).map {
                Owner(key: TodayVoices.Identity.person(personID).key, isMe: false, name: $0)
            }
        case .unassigned:
            owner = nil
        }
    }

    init?(suggestion item: CommitmentReviewQueueItem) {
        guard case .deferredDue(let revisitAt) = item.reason else { return nil }
        id = item.id
        date = revisitAt
        task = item.actionItem.text
        target = .meeting(item.meetingID, at: item.currentEvidence.first?.startTime)
        owner = item.suggestedOwner.flatMap { suggested in
            VoiceCast.name(suggested.displayName).map {
                Owner(key: TodayVoices.Identity.person(suggested.personID).key, isMe: false, name: $0)
            }
        }
    }

    func chip(_ cast: VoiceCast) -> CommitmentDueBoard.Chip {
        CommitmentDueBoard.Chip(
            id: id,
            owner: owner?.name,
            task: task,
            tint: owner.map { $0.isMe ? .you : cast.tint(for: $0.key) } ?? .grey,
            target: target)
    }
}
