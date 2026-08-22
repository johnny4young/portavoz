import Foundation
import Observation
import PortavozCore

struct AskMemoryMeetingAnchor: Identifiable, Equatable {
    let id: MeetingID
    let title: String
    let startedAt: Date
    let endedAt: Date?

    var boundaryAt: Date { endedAt ?? startedAt }
    var usesEndBoundary: Bool { endedAt != nil }
}

enum AskMeetingAnchorsPhase: Equatable {
    case idle
    case loading
    case ready
    case empty
    case unavailable
}

/// Bounded, title-only meeting catalogue for one exact ChangeSince anchor.
/// It never reads transcript or audio, and a late catalogue response cannot
/// replace a newer search or a selected meeting identity.
@MainActor
@Observable
final class AskMeetingAnchorModel {
    struct State {
        fileprivate(set) var query = ""
        fileprivate(set) var meetings: [AskMemoryMeetingAnchor] = []
        fileprivate(set) var phase = AskMeetingAnchorsPhase.idle
        fileprivate(set) var hasMore = false
        fileprivate(set) var selectedMeeting: AskMemoryMeetingAnchor?
    }

    static let visibleMeetingLimit = 20
    private static let meetingRequestLimit = visibleMeetingLimit + 1

    private(set) var state = State()

    private let client: any AskMemoryModelClient
    private let searchDelay: Duration
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    init(
        client: any AskMemoryModelClient,
        searchDelay: Duration = .milliseconds(200)
    ) {
        self.client = client
        self.searchDelay = searchDelay
    }

    isolated deinit {
        searchTask?.cancel()
    }

    func activate() {
        guard state.phase == .idle else { return }
        startSearch(delay: .zero)
    }

    func updateQuery(_ value: String) {
        guard value != state.query else { return }
        state.query = value
        state.selectedMeeting = nil
        startSearch(delay: searchDelay)
    }

    func selectMeeting(_ id: MeetingID) {
        guard let meeting = state.meetings.first(where: { $0.id == id }) else {
            return
        }
        cancelSearch()
        state.query = meeting.title
        state.meetings = []
        state.hasMore = false
        state.phase = .ready
        state.selectedMeeting = meeting
    }

    func clearSelection() {
        state.query = ""
        state.selectedMeeting = nil
        startSearch(delay: .zero)
    }

    func retrySearch() {
        state.selectedMeeting = nil
        startSearch(delay: .zero)
    }

    func reset() {
        cancelSearch()
        state = State()
    }

    func cancelPendingWork() {
        cancelSearch()
        if state.phase == .loading {
            state.phase = .idle
        }
    }

    private func startSearch(delay: Duration) {
        searchGeneration += 1
        let requestGeneration = searchGeneration
        let query = state.query
        searchTask?.cancel()
        state.meetings = []
        state.hasMore = false
        state.phase = .loading
        searchTask = Task { [weak self, client] in
            do {
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
                let meetings = try await client.searchAskMemoryMeetingAnchors(
                    query,
                    limit: Self.meetingRequestLimit)
                try Task.checkCancellation()
                guard let self,
                      self.searchGeneration == requestGeneration
                else { return }
                guard let prepared = Self.prepareMeetings(meetings) else {
                    self.publishUnavailable()
                    return
                }
                self.state.hasMore = prepared.count > Self.visibleMeetingLimit
                self.state.meetings = Array(
                    prepared.prefix(Self.visibleMeetingLimit))
                self.state.phase = self.state.meetings.isEmpty ? .empty : .ready
                self.searchTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.searchGeneration == requestGeneration
                else { return }
                self.publishUnavailable()
            }
        }
    }

    private func cancelSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
    }

    private func publishUnavailable() {
        state.meetings = []
        state.hasMore = false
        state.phase = .unavailable
        searchTask = nil
    }

    private static func prepareMeetings(
        _ meetings: [Meeting]
    ) -> [AskMemoryMeetingAnchor]? {
        guard meetings.count <= meetingRequestLimit else { return nil }
        var ids = Set<MeetingID>()
        var prepared: [AskMemoryMeetingAnchor] = []
        prepared.reserveCapacity(meetings.count)
        for meeting in meetings {
            let title = meeting.title
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !title.isEmpty,
                  ids.insert(meeting.id).inserted,
                  meeting.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  meeting.endedAt?.timeIntervalSinceReferenceDate.isFinite
                    ?? true,
                  meeting.endedAt.map({ $0 >= meeting.startedAt }) ?? true
            else { return nil }
            prepared.append(AskMemoryMeetingAnchor(
                id: meeting.id,
                title: title,
                startedAt: meeting.startedAt,
                endedAt: meeting.endedAt))
        }
        return prepared
    }
}
