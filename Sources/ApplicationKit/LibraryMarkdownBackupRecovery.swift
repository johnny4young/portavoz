import Foundation
import PortavozCore

public enum LibraryMarkdownBackupRecoveryPhase:
    String,
    Codable,
    Equatable,
    Sendable {
    case active
    case completed
}

/// Content-free position of the last source row whose outcome is durably
/// represented by the recovery journal.
public struct LibraryMarkdownBackupSourceCursor:
    Codable,
    Equatable,
    Sendable {
    public let startedAt: Date
    public let recordID: String

    public init(
        startedAt: Date,
        recordID: String
    ) {
        self.startedAt = startedAt
        self.recordID = recordID
    }
}

/// Content-minimized evidence for one destination publication. The journal
/// retains no transcript, summary, or rendered Markdown bytes.
public struct LibraryMarkdownBackupRecoveryPublication:
    Codable,
    Equatable,
    Sendable {
    public let sequence: Int
    public let meetingID: MeetingID
    public let fileName: String
    public let sha256: String
    public let byteCount: Int

    public init(
        sequence: Int,
        meetingID: MeetingID,
        fileName: String,
        sha256: String,
        byteCount: Int
    ) {
        self.sequence = sequence
        self.meetingID = meetingID
        self.fileName = fileName
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public enum LibraryMarkdownBackupRecoveryMutation:
    Equatable,
    Sendable {
    case begin(destinationBookmark: LibraryMarkdownBackupDestinationBookmark)
    case updateDestinationBookmark(LibraryMarkdownBackupDestinationBookmark)
    case reserve(LibraryMarkdownBackupRecoveryPublication)
    case complete(LibraryMarkdownBackupRecoveryPublication)
    case clearReservation
    case checkpointSource(LibraryMarkdownBackupSourceCursor)
    case markCompleted
}

/// Relaunch-readable publication state keyed by the immutable source-stage ID.
/// A source cursor is committed only after its publication is durable.
public struct LibraryMarkdownBackupRecoveryState:
    Codable,
    Equatable,
    Sendable {
    public let operationID: UUID
    public var destinationBookmark: LibraryMarkdownBackupDestinationBookmark
    public var sourceCursor: LibraryMarkdownBackupSourceCursor?
    public var completedPublications: [LibraryMarkdownBackupRecoveryPublication]
    public var pendingPublication: LibraryMarkdownBackupRecoveryPublication?
    public var phase: LibraryMarkdownBackupRecoveryPhase

    public init(
        operationID: UUID,
        destinationBookmark: LibraryMarkdownBackupDestinationBookmark,
        sourceCursor: LibraryMarkdownBackupSourceCursor? = nil,
        completedPublications: [LibraryMarkdownBackupRecoveryPublication] = [],
        pendingPublication: LibraryMarkdownBackupRecoveryPublication? = nil,
        phase: LibraryMarkdownBackupRecoveryPhase = .active
    ) {
        self.operationID = operationID
        self.destinationBookmark = destinationBookmark
        self.sourceCursor = sourceCursor
        self.completedPublications = completedPublications
        self.pendingPublication = pendingPublication
        self.phase = phase
    }
}

/// Private durable state used to reconcile the atomic move/manifest crash
/// window. Implementations fail closed when persisted state is malformed.
public protocol LibraryMarkdownBackupRecoveryStore: Sendable {
    func apply(
        _ mutation: LibraryMarkdownBackupRecoveryMutation,
        operationID: UUID
    ) async throws
    func load(
        operationID: UUID
    ) async throws -> LibraryMarkdownBackupRecoveryState?
    func remove(operationID: UUID) async throws
}
