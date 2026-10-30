import Foundation

/// One call-ended question belongs to one recording and expires when withdrawn.
public struct CallEndedNotificationFence: Sendable {
    public struct Ticket: Equatable, Sendable {
        public let sessionID: UUID
        public let identifier: String
    }

    public private(set) var current: Ticket?

    public init() {}

    public mutating func begin(sessionID: UUID) -> Ticket {
        let ticket = Ticket(sessionID: sessionID, identifier: "portavoz.call-ended.\(UUID().uuidString)")
        current = ticket
        return ticket
    }

    @discardableResult
    public mutating func withdraw() -> Ticket? {
        defer { current = nil }
        return current
    }

    public func accepts(identifier: String?, sessionID: UUID, isRecording: Bool) -> Bool {
        guard isRecording, let current else { return false }
        return current.identifier == identifier && current.sessionID == sessionID
    }
}
