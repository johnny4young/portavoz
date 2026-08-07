import Foundation

public struct AudioInputOption: Identifiable, Equatable, Sendable {
    public let uid: String
    public let name: String

    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public protocol AudioInputListing: Sendable {
    func audioInputOptions() async throws -> [AudioInputOption]
}

public struct LoadAudioInputOptions: ApplicationUseCase {
    private let inputs: any AudioInputListing

    public init(inputs: any AudioInputListing) {
        self.inputs = inputs
    }

    public func execute(_ request: Void) async throws -> [AudioInputOption] {
        try await inputs.audioInputOptions()
    }
}

public struct RecordingStorageLocation: Equatable, Sendable {
    public let currentRoot: URL
    public let defaultRoot: URL
    public let isCustom: Bool

    public init(currentRoot: URL, defaultRoot: URL, isCustom: Bool) {
        self.currentRoot = currentRoot
        self.defaultRoot = defaultRoot
        self.isCustom = isCustom
    }
}

public struct RecordingStorageProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = max(0, completed)
        self.total = max(0, total)
    }
}

public typealias RecordingStorageProgressHandler =
    @Sendable (RecordingStorageProgress) async -> Void

public protocol RecordingStorageManaging: Sendable {
    func recordingStorageLocation() async -> RecordingStorageLocation
    func migrateRecordingStorage(
        to destination: URL?,
        progress: @escaping RecordingStorageProgressHandler
    ) async throws -> Int
}

public enum ManageRecordingStorageAction: Sendable {
    case inspect
    /// `nil` restores the default root.
    case move(to: URL?)
}

public struct ManageRecordingStorageRequest: Sendable {
    public let action: ManageRecordingStorageAction
    public let progress: RecordingStorageProgressHandler

    public init(
        action: ManageRecordingStorageAction,
        progress: @escaping RecordingStorageProgressHandler = { _ in }
    ) {
        self.action = action
        self.progress = progress
    }
}

public enum ManageRecordingStorageResult: Equatable, Sendable {
    case location(RecordingStorageLocation)
    case moved(location: RecordingStorageLocation, recordingCount: Int)
}

/// Whether capture or post-capture work still owns files under the recordings
/// root. Migration must not run while it does.
public protocol RecordingStorageActivity: Sendable {
    func recordingStorageIsBusy() async -> Bool
}

public enum ManageRecordingStorageError: Error, Equatable, LocalizedError, Sendable {
    /// A meeting is recording or still being processed, so its audio files are
    /// open. Moving them now would unlink the directory underneath the writers.
    case recordingInProgress

    /// The migration failed *and* could not put back everything it had moved.
    /// Carried as its own case because every other failure is a true no-op —
    /// telling the user "nothing was lost" here would be false, and the folder
    /// and count are the only two facts that let them recover.
    case recordingsStranded(count: Int, path: String)

    public var errorDescription: String? {
        switch self {
        case .recordingInProgress:
            "Finish the current recording before moving the recordings folder."
        case .recordingsStranded(let count, let path):
            """
            \(count) recording(s) were moved to \(path) and could not be put \
            back. They are safe there: move them into the Audio folder of your \
            recordings location, or point Portavoz at that folder.
            """
        }
    }
}

/// Coordinates the durable recording-root change while keeping filesystem
/// and marker-file behavior in an injected outer adapter.
///
/// Migration copies and then **deletes** each meeting directory when the
/// destination is on another volume, so a live capture's directory would be
/// unlinked while its writers still hold it open — every sample after the copy
/// point lands in an unlinked inode and Stop reports the truncated copy as
/// preserved audio. Recording safety outranks the setting, so this fails
/// closed instead.
public struct ManageRecordingStorage: ApplicationUseCase {
    private let storage: any RecordingStorageManaging
    private let activity: (any RecordingStorageActivity)?

    public init(
        storage: any RecordingStorageManaging,
        activity: (any RecordingStorageActivity)? = nil
    ) {
        self.storage = storage
        self.activity = activity
    }

    public func execute(
        _ request: ManageRecordingStorageRequest
    ) async throws -> ManageRecordingStorageResult {
        switch request.action {
        case .inspect:
            return .location(await storage.recordingStorageLocation())
        case .move(let destination):
            if await activity?.recordingStorageIsBusy() == true {
                throw ManageRecordingStorageError.recordingInProgress
            }
            let count = try await storage.migrateRecordingStorage(
                to: destination,
                progress: request.progress)
            return .moved(
                location: await storage.recordingStorageLocation(),
                recordingCount: count)
        }
    }
}

/// Safe projection for Settings. Voice embeddings never enter presentation.
public struct RememberedVoiceSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let createdAt: Date

    public init(id: UUID, name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public protocol RememberedVoiceCatalogManaging: Sendable {
    func rememberedVoiceSummaries() async throws -> [RememberedVoiceSummary]
    func removeRememberedVoice(id: UUID) async throws
    func removeAllRememberedVoices() async throws
}

public enum ManageRememberedVoicesRequest: Sendable {
    case list
    case remove(UUID)
    case removeAll
}

public enum ManageRememberedVoicesResult: Equatable, Sendable {
    case voices([RememberedVoiceSummary])
    case removed
}

/// Keeps encrypted gallery reads and destructive writes behind one explicit
/// Settings workflow. A failed deletion remains a failure to presentation.
public struct ManageRememberedVoices: ApplicationUseCase {
    private let catalog: any RememberedVoiceCatalogManaging

    public init(catalog: any RememberedVoiceCatalogManaging) {
        self.catalog = catalog
    }

    public func execute(
        _ request: ManageRememberedVoicesRequest
    ) async throws -> ManageRememberedVoicesResult {
        switch request {
        case .list:
            return .voices(try await catalog.rememberedVoiceSummaries())
        case .remove(let id):
            try await catalog.removeRememberedVoice(id: id)
            return .removed
        case .removeAll:
            try await catalog.removeAllRememberedVoices()
            return .removed
        }
    }
}
