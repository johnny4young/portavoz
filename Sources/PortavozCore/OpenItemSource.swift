import Foundation

/// Where an open to-do came from: who said it, when, who owns it and when it is due.
public struct OpenItemSource: Sendable, Equatable {
    /// A meeting's speaker, or the person a confirmed commitment is assigned to.
    public struct Voice: Sendable, Equatable {
        /// Nil for a commitment's assignee, who is a person rather than a voice.
        public let speakerID: SpeakerID?
        public let isMe: Bool
        public let label: String
        public let displayName: String?
        public let personID: PersonID?

        public init(
            speakerID: SpeakerID?, isMe: Bool, label: String, displayName: String?, personID: PersonID? = nil
        ) {
            self.speakerID = speakerID
            self.isMe = isMe
            self.label = label
            self.displayName = displayName
            self.personID = personID
        }

        func isSamePerson(as other: Voice) -> Bool {
            if isMe || other.isMe { return isMe == other.isMe }
            if let personID, personID == other.personID { return true }
            return speakerID != nil && speakerID == other.speakerID
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
        return saidBy.isSamePerson(as: owner)
    }
}
