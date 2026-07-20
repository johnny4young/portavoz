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

public struct LocalVoiceSample: Sendable {
    public static let minimumEnrollmentDuration: TimeInterval = 4

    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }
}

public enum LocalVoiceCaptureMode: Equatable, Sendable {
    case raw
    case echoCancelled
}

public enum LocalVoiceEnrollmentProgress: Equatable, Sendable {
    case capturing(secondsRemaining: Int)
    case extracting
    case persisting
}

public typealias LocalVoiceEnrollmentProgressHandler =
    @Sendable (LocalVoiceEnrollmentProgress) async -> Void

public protocol LocalVoiceSampleCapturing: Sendable {
    func captureVoiceSample(
        seconds: Int,
        mode: LocalVoiceCaptureMode,
        progress: @escaping LocalVoiceEnrollmentProgressHandler
    ) async throws -> LocalVoiceSample
}

public protocol LocalVoiceSampleIdentityExtracting: Sendable {
    func extractVoiceIdentity(from sample: LocalVoiceSample) async throws -> Voiceprint
}

public enum ManageLocalVoiceIdentityRequest: Sendable {
    case enroll(fileURL: URL)
    case enrollSample(
        LocalVoiceSample,
        progress: LocalVoiceEnrollmentProgressHandler = { _ in })
    case recordAndEnroll(
        seconds: Int,
        mode: LocalVoiceCaptureMode,
        progress: LocalVoiceEnrollmentProgressHandler = { _ in })
    case status
    case delete
}

public enum ManageLocalVoiceIdentityResult: Sendable {
    case enrolled(Voiceprint)
    case status(Voiceprint?)
    case deleted
}

public enum ManageLocalVoiceIdentityError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedEnrollmentSource
    case invalidCaptureDuration
    case invalidSample

    public var errorDescription: String? {
        switch self {
        case .unsupportedEnrollmentSource:
            "This voice enrollment source is unavailable."
        case .invalidCaptureDuration:
            "Voice enrollment duration must be between 1 and 60 seconds."
        case .invalidSample:
            "The voice sample is too short or invalid."
        }
    }
}

/// Voice enrollment policy independent from Keychain, model, and filesystem
/// implementations. The source audio is read by the extractor and never kept.
public struct ManageLocalVoiceIdentity: ApplicationUseCase {
    private let files: (any ApplicationInputFileAccess)?
    private let identities: any LocalVoiceIdentityStoring
    private let fileExtractor: (any LocalVoiceIdentityExtracting)?
    private let sampleCapture: (any LocalVoiceSampleCapturing)?
    private let sampleExtractor: (any LocalVoiceSampleIdentityExtracting)?

    public init(
        files: any ApplicationInputFileAccess,
        identities: any LocalVoiceIdentityStoring,
        extractor: any LocalVoiceIdentityExtracting
    ) {
        self.files = files
        self.identities = identities
        fileExtractor = extractor
        sampleCapture = nil
        sampleExtractor = nil
    }

    public init(
        sampleCapture: any LocalVoiceSampleCapturing,
        identities: any LocalVoiceIdentityStoring,
        sampleExtractor: any LocalVoiceSampleIdentityExtracting
    ) {
        files = nil
        self.identities = identities
        fileExtractor = nil
        self.sampleCapture = sampleCapture
        self.sampleExtractor = sampleExtractor
    }

    public func execute(
        _ request: ManageLocalVoiceIdentityRequest
    ) async throws -> ManageLocalVoiceIdentityResult {
        switch request {
        case .enroll(let fileURL):
            guard let files, let fileExtractor else {
                throw ManageLocalVoiceIdentityError.unsupportedEnrollmentSource
            }
            guard await files.isReadableFile(fileURL) else {
                throw AnalyzeAudioFileError.inputFileNotFound(fileURL.path)
            }
            let voiceprint = try await fileExtractor.extractVoiceIdentity(from: fileURL)
            try await identities.saveVoiceIdentity(voiceprint)
            return .enrolled(voiceprint)
        case .enrollSample(let sample, let progress):
            return try await enroll(sample: sample, progress: progress)
        case .recordAndEnroll(let seconds, let mode, let progress):
            guard (1...60).contains(seconds) else {
                throw ManageLocalVoiceIdentityError.invalidCaptureDuration
            }
            guard let sampleCapture else {
                throw ManageLocalVoiceIdentityError.unsupportedEnrollmentSource
            }
            await progress(.capturing(secondsRemaining: seconds))
            let sample = try await sampleCapture.captureVoiceSample(
                seconds: seconds,
                mode: mode,
                progress: progress)
            return try await enroll(sample: sample, progress: progress)
        case .status:
            return .status(try await identities.loadVoiceIdentity())
        case .delete:
            try await identities.deleteVoiceIdentity()
            return .deleted
        }
    }

    private func enroll(
        sample: LocalVoiceSample,
        progress: @escaping LocalVoiceEnrollmentProgressHandler
    ) async throws -> ManageLocalVoiceIdentityResult {
        guard sample.sampleRate.isFinite, sample.sampleRate > 0,
              sample.duration >= LocalVoiceSample.minimumEnrollmentDuration,
              sample.samples.allSatisfy(\.isFinite)
        else { throw ManageLocalVoiceIdentityError.invalidSample }
        guard let sampleExtractor else {
            throw ManageLocalVoiceIdentityError.unsupportedEnrollmentSource
        }
        await progress(.extracting)
        let voiceprint = try await sampleExtractor.extractVoiceIdentity(from: sample)
        await progress(.persisting)
        try await identities.saveVoiceIdentity(voiceprint)
        return .enrolled(voiceprint)
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
            // A failed install throws out of the loop on purpose: each model
            // is verified atomically (sha256 + proven loadable) by the store,
            // already-installed models remain usable, and the caller renders
            // the failure instead of a silently partial "installed" result.
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
