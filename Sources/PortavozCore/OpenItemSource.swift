import Foundation

/// Where an open to-do came from: who said it, when, who owns it and when it is due.
public struct OpenItemSource: Sendable, Equatable {
    public struct Voice: Sendable, Equatable {
        public let speakerID: SpeakerID
        public let isMe: Bool
        public let label: String
        public let displayName: String?

        public init(speakerID: SpeakerID, isMe: Bool, label: String, displayName: String?) {
            self.speakerID = speakerID
            self.isMe = isMe
            self.label = label
            self.displayName = displayName
        }
    }

    /// Whoever spoke the item's first evidence line, after speaker corrections.
    public let saidBy: Voice?
    /// Start of that line in the meeting.
    public let time: TimeInterval?
    public let owner: Voice?
    /// Due date of the confirmed commitment the item became.
    public let dueAt: Date?

    public init(saidBy: Voice?, time: TimeInterval?, owner: Voice?, dueAt: Date?) {
        self.saidBy = saidBy
        self.time = time
        self.owner = owner
        self.dueAt = dueAt
    }

    /// The owner asked for it when someone else said it.
    public var ownerSaidIt: Bool {
        guard let saidBy, let owner else { return true }
        return saidBy.speakerID == owner.speakerID
    }
}
