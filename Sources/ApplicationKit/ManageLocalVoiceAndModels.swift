import DiarizationKit
import Foundation

public protocol LocalVoiceIdentityStoring: Sendable {
    func loadVoiceIdentity() async throws -> Voiceprint?
    func saveVoiceIdentity(_ voiceprint: Voiceprint) async throws
    func deleteVoiceIdentity() async throws
}

public protocol LocalVoiceIdentityExtracting: Sendable {
    func extractVoiceIdentity(from fileURL: URL) async throws -> Voiceprint
}

public enum ManageLocalVoiceIdentityRequest: Sendable {
    case enroll(fileURL: URL)
    case status
    case delete
}

public enum ManageLocalVoiceIdentityResult: Sendable {
    case enrolled(Voiceprint)
    case status(Voiceprint?)
    case deleted
}

/// Voice enrollment policy independent from Keychain, model, and filesystem
/// implementations. The source audio is read by the extractor and never kept.
public struct ManageLocalVoiceIdentity: ApplicationUseCase {
    private let files: any ApplicationInputFileAccess
    private let identities: any LocalVoiceIdentityStoring
    private let extractor: any LocalVoiceIdentityExtracting

    public init(
        files: any ApplicationInputFileAccess,
        identities: any LocalVoiceIdentityStoring,
        extractor: any LocalVoiceIdentityExtracting
    ) {
        self.files = files
        self.identities = identities
        self.extractor = extractor
    }

    public func execute(
        _ request: ManageLocalVoiceIdentityRequest
    ) async throws -> ManageLocalVoiceIdentityResult {
        switch request {
        case .enroll(let fileURL):
            guard await files.isReadableFile(fileURL) else {
                throw AnalyzeAudioFileError.inputFileNotFound(fileURL.path)
            }
            let voiceprint = try await extractor.extractVoiceIdentity(from: fileURL)
            try await identities.saveVoiceIdentity(voiceprint)
            return .enrolled(voiceprint)
        case .status:
            return .status(try await identities.loadVoiceIdentity())
        case .delete:
            try await identities.deleteVoiceIdentity()
            return .deleted
        }
    }
}

public struct LocalModelDescriptor: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let revision: String
    public let totalSizeMegabytes: Int
    public let artifactCount: Int

    public init(
        id: String,
        displayName: String,
        revision: String,
        totalSizeMegabytes: Int,
        artifactCount: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.revision = revision
        self.totalSizeMegabytes = totalSizeMegabytes
        self.artifactCount = artifactCount
    }
}

public struct LocalModelVerification: Equatable, Sendable {
    public let descriptor: LocalModelDescriptor
    public let directory: URL
    public let missing: [String]
    public let corrupted: [String]

    public init(
        descriptor: LocalModelDescriptor,
        directory: URL,
        missing: [String],
        corrupted: [String]
    ) {
        self.descriptor = descriptor
        self.directory = directory
        self.missing = missing
        self.corrupted = corrupted
    }

    public var verifiedArtifactCount: Int {
        descriptor.artifactCount - missing.count - corrupted.count
    }

    public var isComplete: Bool { missing.isEmpty && corrupted.isEmpty }
}

public protocol LocalModelLifecycleManaging: Sendable {
    var catalog: [LocalModelDescriptor] { get }
    func verification(for descriptor: LocalModelDescriptor) async -> LocalModelVerification
    func installAndProveLoadable(
        _ descriptor: LocalModelDescriptor,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws
}

public enum ManageLocalModelsAction: Sendable {
    case paths
    case verify
    case download
}

public struct ManageLocalModelsRequest: Sendable {
    public let action: ManageLocalModelsAction
    public let progress: AudioAnalysisProgressHandler

    public init(
        action: ManageLocalModelsAction,
        progress: @escaping AudioAnalysisProgressHandler = { _ in }
    ) {
        self.action = action
        self.progress = progress
    }
}

public enum ManageLocalModelsResult: Sendable {
    case inspected([LocalModelVerification])
    case installed([LocalModelDescriptor])
}

/// Operates only on the pinned catalog exposed by the injected model adapter.
public struct ManageLocalModels: ApplicationUseCase {
    private let models: any LocalModelLifecycleManaging

    public init(models: any LocalModelLifecycleManaging) {
        self.models = models
    }

    public func execute(
        _ request: ManageLocalModelsRequest
    ) async throws -> ManageLocalModelsResult {
        switch request.action {
        case .paths, .verify:
            var reports: [LocalModelVerification] = []
            reports.reserveCapacity(models.catalog.count)
            for descriptor in models.catalog {
                reports.append(await models.verification(for: descriptor))
            }
            return .inspected(reports)
        case .download:
            var installed: [LocalModelDescriptor] = []
            installed.reserveCapacity(models.catalog.count)
            for descriptor in models.catalog {
                try await models.installAndProveLoadable(
                    descriptor,
                    progress: request.progress)
                installed.append(descriptor)
                await request.progress(.installedModel(name: descriptor.displayName))
            }
            return .installed(installed)
        }
    }
}
