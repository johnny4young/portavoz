import Foundation

/// Where listening to a meeting last stopped. A meeting never played has none.
public struct MeetingPlaybackPosition: Equatable, Sendable {
    /// Positions this close to either end open the meeting from the start.
    public static let resumeMargin: TimeInterval = 1

    public let meetingID: MeetingID
    public let seconds: TimeInterval
    /// Played to the end at least once; later listening keeps it heard.
    public let isHeard: Bool
    public let updatedAt: Date

    public init(meetingID: MeetingID, seconds: TimeInterval, isHeard: Bool, updatedAt: Date) {
        self.meetingID = meetingID
        self.seconds = seconds.isFinite ? max(0, seconds) : 0
        self.isHeard = isHeard
        self.updatedAt = updatedAt
    }

    /// The time a player of `duration` should open at, or nil to open at the start.
    public func resumeTime(duration: TimeInterval) -> TimeInterval? {
        guard seconds >= Self.resumeMargin, seconds < duration - Self.resumeMargin else { return nil }
        return seconds
    }
}
