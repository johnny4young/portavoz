import Foundation
import PortavozCore

/// One meeting row projected specifically for the resident macOS menu-bar
/// surface. It carries only the fields that surface renders.
public struct MenuBarMeeting: Equatable, Identifiable, Sendable {
    public let id: MeetingID
    public let title: String
    public let startedAt: Date
    /// Who spoke when; nil before anything was attributed.
    public let strip: VoiceStripSource?

    public init(id: MeetingID, title: String, startedAt: Date, strip: VoiceStripSource? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.strip = strip
    }
}

/// Independently observed menu-bar query families. One failed projection must
/// not erase healthy resident-surface state.
public enum MenuBarReadSection: CaseIterable, Hashable, Sendable {
    case meetings
    case pendingCounts
}

/// Storage-independent updates consumed by the menu bar's presentation owner.
public enum MenuBarUpdate: Sendable {
    case meetings([MenuBarMeeting])
    case pendingCounts([MeetingID: Int])
    case failed(MenuBarReadSection)
}
