import Foundation
import PortavozCore
import StorageKit

/// Storage projection needed to decide which tombstones have expired.
public struct MeetingPurgeCandidate: Equatable, Sendable {
    public let meetingID: MeetingID
    public let audioDirectory: String?
    public let deletedAt: Date

    public init(meetingID: MeetingID, audioDirectory: String?, deletedAt: Date) {
        self.meetingID = meetingID
        self.audioDirectory = audioDirectory
        self.deletedAt = deletedAt
    }
}

/// Narrow storage port for permanent deletion and trash expiry.
public protocol MeetingPurgeStore: Sendable {
    func purge(_ id: MeetingID) async throws
    func meetingPurgeCandidates() async throws -> [MeetingPurgeCandidate]
    func meetingPurgeCandidate(_ id: MeetingID) async throws -> MeetingPurgeCandidate?
}

extension MeetingStore: MeetingPurgeStore {
    public func meetingPurgeCandidate(_ id: MeetingID) async throws -> MeetingPurgeCandidate? {
        guard let entry = try await deletedMeeting(id) else { return nil }
        return MeetingPurgeCandidate(meetingID: id, audioDirectory: entry.meeting.audioDirectory,
                                     deletedAt: entry.deletedAt)
    }

    public func meetingPurgeCandidates() async throws -> [MeetingPurgeCandidate] {
        try await deletedMeetings().map {
            MeetingPurgeCandidate(
                meetingID: $0.meeting.id,
                audioDirectory: $0.meeting.audioDirectory,
                deletedAt: $0.deletedAt)
        }
    }
}

/// Filesystem capability kept outside ApplicationKit's orchestration.
public protocol MeetingAudioFiles: Sendable {
    func removeAudioDirectory(_ relativePath: String) async throws
}

public struct PurgeMeetingRequest: Equatable, Sendable {
    public let meetingID: MeetingID
    public let deletedBefore: Date?

    public init(meetingID: MeetingID, deletedBefore: Date? = nil) {
        self.meetingID = meetingID
        self.deletedBefore = deletedBefore
    }
}

public struct PurgeMeetingResult: Equatable, Sendable {
    /// True when there was no referenced directory or removal completed.
    public let audioRemovalSucceeded: Bool
}

/// Permanently removes audio best-effort, then purges the tombstoned aggregate.
///
/// Once acquisition exclusion is held, audio-removal failure must not prevent
/// database purge: that is the released privacy behavior. A busy acquisition
/// or storage failure propagates; neither is reported as successful removal.
public struct PurgeMeeting: ApplicationUseCase {
    private let store: any MeetingPurgeStore
    private let audioFiles: any MeetingAudioFiles
    private let acquisition: (any AudioImportFiles)?

    public init(store: any MeetingPurgeStore, audioFiles: any MeetingAudioFiles,
                acquisition: (any AudioImportFiles)? = nil) {
        self.store = store
        self.audioFiles = audioFiles
        self.acquisition = acquisition
    }

    public func execute(_ request: PurgeMeetingRequest) async throws -> PurgeMeetingResult {
        if let acquisition {
            return try await acquisition.withAcquisitionAccess { try await purge(request) }
        }
        return try await purge(request)
    }

    private func purge(_ request: PurgeMeetingRequest) async throws -> PurgeMeetingResult {
        guard let candidate = try await store.meetingPurgeCandidate(request.meetingID),
              request.deletedBefore.map({ candidate.deletedAt < $0 }) ?? true else {
            return PurgeMeetingResult(audioRemovalSucceeded: true)
        }
        var audioRemovalSucceeded = true
        if let relativePath = candidate.audioDirectory {
            do {
                try await audioFiles.removeAudioDirectory(relativePath)
            } catch {
                audioRemovalSucceeded = false
            }
        }
        try await store.purge(request.meetingID)
        return PurgeMeetingResult(audioRemovalSucceeded: audioRemovalSucceeded)
    }
}

/// Purges every tombstone strictly older than the supplied cutoff.
/// Individual failures remain best-effort so one damaged entry cannot block
/// later expired meetings, matching the released launch cleanup behavior.
public struct PurgeExpiredTrash: ApplicationUseCase {
    private let store: any MeetingPurgeStore
    private let purgeMeeting: PurgeMeeting

    public init(store: any MeetingPurgeStore, audioFiles: any MeetingAudioFiles,
                acquisition: (any AudioImportFiles)? = nil) {
        self.store = store
        purgeMeeting = PurgeMeeting(store: store, audioFiles: audioFiles, acquisition: acquisition)
    }

    public func execute(_ cutoff: Date) async throws -> Int {
        let expired = try await store.meetingPurgeCandidates()
            .filter { $0.deletedAt < cutoff }
        for candidate in expired {
            let request = PurgeMeetingRequest(meetingID: candidate.meetingID, deletedBefore: cutoff)
            _ = try? await purgeMeeting.execute(request)
        }
        return expired.count
    }
}

/// Cohesive composition value for manual and launch-time purge workflows.
public struct MeetingPurgeUseCases: Sendable {
    public let purge: PurgeMeeting
    public let expired: PurgeExpiredTrash

    public init(store: any MeetingPurgeStore, audioFiles: any MeetingAudioFiles,
                acquisition: (any AudioImportFiles)? = nil) {
        purge = PurgeMeeting(store: store, audioFiles: audioFiles, acquisition: acquisition)
        expired = PurgeExpiredTrash(store: store, audioFiles: audioFiles, acquisition: acquisition)
    }
}
