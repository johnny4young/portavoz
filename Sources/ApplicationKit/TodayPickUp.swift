import Foundation
import PortavozCore

/// Today's "Pick up where you left off": meetings stopped part way first, most
/// recently listened leading, then meetings never played, newest first. A
/// meeting heard to the end has nothing left to pick up.
public enum TodayPickUp {
    public static let maximumRows = 3
    /// Open to-dos Today lists beside the pick-up rows.
    public static let maximumOpenItems = 5
    /// Recent meetings whose saved position Today reads.
    public static let candidateLimit = 20

    public enum Progress: Sendable, Equatable {
        case stopped(at: TimeInterval)
        case unheard
    }

    public struct Row: Sendable, Identifiable {
        public let meeting: Meeting
        /// Nil until saved positions have been read.
        public let progress: Progress?
        public var id: MeetingID { meeting.id }

        /// How much of a strip spanning `duration` was played, 0…1; nil while unknown.
        public func playedFraction(of duration: TimeInterval) -> Double? {
            switch progress {
            case nil: return nil
            case .unheard: return 0
            case .stopped(let seconds):
                let span = duration > 0 ? duration : meeting.listeningDuration ?? 0
                return span > 0 ? min(1, max(0, seconds / span)) : 0
            }
        }
    }

    /// Finished meetings, newest first as the library lists them.
    public static func candidates(_ meetings: [Meeting]) -> [Meeting] {
        Array(meetings.lazy.filter { $0.listeningDuration != nil }.prefix(candidateLimit))
    }

    /// Without positions yet, the newest finished meetings with no progress.
    public static func rows(
        meetings: [Meeting], positions: [MeetingID: MeetingPlaybackPosition]?, limit: Int = maximumRows
    ) -> [Row] {
        let candidates = candidates(meetings)
        guard let positions else {
            return candidates.prefix(max(0, limit)).map { Row(meeting: $0, progress: nil) }
        }
        var stopped: [(row: Row, listenedAt: Date)] = []
        var unheard: [Row] = []
        for meeting in candidates {
            if let position = positions[meeting.id] {
                if position.isHeard { continue }
                if let duration = meeting.listeningDuration, let time = position.resumeTime(duration: duration) {
                    stopped.append((Row(meeting: meeting, progress: .stopped(at: time)), position.updatedAt))
                    continue
                }
            }
            unheard.append(Row(meeting: meeting, progress: .unheard))
        }
        let ordered = stopped.sorted { $0.listenedAt > $1.listenedAt }.map(\.row) + unheard
        return Array(ordered.prefix(max(0, limit)))
    }
}

extension Meeting {
    /// Length of a finished meeting, the span its voice strip covers.
    var listeningDuration: TimeInterval? {
        guard lifecycleState != .recording, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}
