import DiarizationKit
import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit
import TranscriptionKit

/// Storage boundary for owner-leased post-capture work. Artifact publication
/// remains atomic in StorageKit; this workflow owns ordering and policy.
public protocol PostCaptureProcessingStore: Sendable {
    func claimPostCaptureJob(
        kinds: Set<ProcessingJobKind>,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) async throws -> ProcessingJob?
    func heartbeatPostCaptureJob(
        _ id: ProcessingJobID,
        owner: String,
        progress: Double,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) async throws
    func postCaptureDetail(_ meetingID: MeetingID) async throws -> MeetingDetail?
    func postCaptureAudioAssets(_ meetingID: MeetingID) async throws -> [AudioAsset]
    func postCaptureContextItems(_ meetingID: MeetingID) async throws -> [ContextItem]
    func publishPostCaptureTranscription(
        _ jobID: ProcessingJobID,
        owner: String,
        artifact: TranscriptionArtifact,
        followUps: [ProcessingJobRequest],
        at timestamp: Date
    ) async throws -> ProcessingArtifactCommit
    func publishPostCaptureDiarization(
        _ jobID: ProcessingJobID,
        owner: String,
        artifact: DiarizationArtifact,
        followUps: [ProcessingJobRequest],
        at timestamp: Date
    ) async throws -> ProcessingArtifactCommit
    func publishPostCaptureSummary(
        _ jobID: ProcessingJobID,
        owner: String,
        artifact: SummaryArtifact,
        at timestamp: Date
    ) async throws
    func savePostCaptureGenerationRun(_ run: GenerationRun) async throws
    func failPostCaptureJob(
        _ jobID: ProcessingJobID,
        owner: String,
        failure: ProcessingJobFailure,
        retryAt: Date?,
        at timestamp: Date
    ) async throws
    func cancelPostCaptureJob(
        _ jobID: ProcessingJobID,
        owner: String,
        reason: ProcessingJobFailure,
        at timestamp: Date
    ) async throws
    func nextPostCaptureProcessingDate(
        kinds: Set<ProcessingJobKind>,
        after timestamp: Date
    ) async throws -> Date?
}

public struct PostCaptureSummaryProviderSelection: Sendable {
    public let provider: any SummaryProvider
    public let providerID: String
    public let modelID: String
    public let modelRevision: String?

    public init(
        provider: any SummaryProvider,
        providerID: String,
        modelID: String,
        modelRevision: String?
    ) {
        self.provider = provider
        self.providerID = providerID
        self.modelID = modelID
        self.modelRevision = modelRevision
    }
}

public struct PostCaptureSummaryPreferences: Sendable {
    public let outputLanguage: String
    public let vocabulary: [String]

    public init(outputLanguage: String, vocabulary: [String]) {
        self.outputLanguage = outputLanguage
        self.vocabulary = vocabulary
    }
}

/// Concrete audio engines and files stay in executable composition. The
/// workflow receives only model results and explicit lifecycle effects.
public protocol PostCaptureAudioProcessing: Sendable {
    func transcribePostCaptureAudio(
        _ asset: AudioAsset,
        channel: AudioChannel,
        hints: TranscriptionHints
    ) async throws -> FileTranscription
    func currentPostCaptureVoiceprint() async -> Voiceprint?
    func diarizePostCaptureAudio(_ asset: AudioAsset) async throws -> [SpeakerTurn]
    func schedulePostCaptureIdleRelease() async
}

/// Samples the currently configured summary provider and output preferences
/// without exposing persistence, model paths, or platform availability.
public protocol PostCaptureSummaryConfiguration: Sendable {
    func postCaptureSummaryProvider() async -> PostCaptureSummaryProviderSelection?
    func postCaptureSummaryPreferences(
        spokenLanguage: String?
    ) async -> PostCaptureSummaryPreferences
}

/// Best-effort external automation triggered only after the durable workflow's
/// exact completion conditions have been satisfied.
public protocol PostCaptureCompletionActions: Sendable {
    func runPostMeetingAction(for meetingID: MeetingID) async
}

public enum PostCaptureProcessingCapabilityError: Error, Equatable, LocalizedError, Sendable {
    case audioUnavailable

    public var errorDescription: String? {
        "The finalized capture audio is no longer available."
    }
}

public enum PostCaptureProcessingOutcome: String, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case leaseLost
}

public enum PostCaptureProcessingIssueStage: Equatable, Sendable {
    case claim
    case failurePreservation(ProcessingJobKind)
}

public struct PostCaptureProcessingIssue: Equatable, Sendable {
    public let stage: PostCaptureProcessingIssueStage
    public let message: String

    public init(stage: PostCaptureProcessingIssueStage, message: String) {
        self.stage = stage
        self.message = message
    }
}

public enum PostCaptureProcessingEvent: Equatable, Sendable {
    case started(kind: ProcessingJobKind, attempt: Int)
    case finished(
        kind: ProcessingJobKind,
        attempt: Int,
        outcome: PostCaptureProcessingOutcome,
        durableStateChanged: Bool)
}

public typealias PostCaptureProcessingEventHandler =
    @Sendable (PostCaptureProcessingEvent) async -> Void

public struct ProcessPostCaptureJobsRequest: Sendable {
    public let owner: String
    public let progress: PostCaptureProcessingEventHandler

    public init(
        owner: String,
        progress: @escaping PostCaptureProcessingEventHandler = { _ in }
    ) {
        self.owner = owner
        self.progress = progress
    }
}

public struct ProcessPostCaptureJobsResult: Sendable {
    public let processedJobCount: Int
    public let durableStateChanged: Bool
    public let issues: [PostCaptureProcessingIssue]

    public init(
        processedJobCount: Int,
        durableStateChanged: Bool,
        issues: [PostCaptureProcessingIssue]
    ) {
        self.processedJobCount = processedJobCount
        self.durableStateChanged = durableStateChanged
        self.issues = issues
    }
}

/// Drains due owner-leased work serially. It owns durable state transitions,
/// dependency ordering, retry policy, and artifact fingerprints.
public struct ProcessPostCaptureJobs: ApplicationUseCase {
    public static let supportedKinds: Set<ProcessingJobKind> = [
        .transcription, .diarization, .summary
    ]

    private let store: any PostCaptureProcessingStore
    private let audio: any PostCaptureAudioProcessing
    private let summaries: any PostCaptureSummaryConfiguration
    private let actions: any PostCaptureCompletionActions
    private let leaseDuration: TimeInterval
    private let heartbeatInterval: Duration
    private let now: @Sendable () -> Date

    public init(
        store: any PostCaptureProcessingStore,
        audio: any PostCaptureAudioProcessing,
        summaries: any PostCaptureSummaryConfiguration,
        actions: any PostCaptureCompletionActions,
        leaseDuration: TimeInterval = 120,
        heartbeatInterval: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.audio = audio
        self.summaries = summaries
        self.actions = actions
        self.leaseDuration = leaseDuration
        self.heartbeatInterval = heartbeatInterval
        self.now = now
    }

    /// Composition roots may implement the three narrow ports with one
    /// process adapter without widening the workflow's internal dependencies.
    public init<Capabilities>(
        store: any PostCaptureProcessingStore,
        capabilities: Capabilities,
        leaseDuration: TimeInterval = 120,
        heartbeatInterval: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() }
    ) where Capabilities: PostCaptureAudioProcessing,
        Capabilities: PostCaptureSummaryConfiguration,
        Capabilities: PostCaptureCompletionActions {
        self.init(
            store: store,
            audio: capabilities,
            summaries: capabilities,
            actions: capabilities,
            leaseDuration: leaseDuration,
            heartbeatInterval: heartbeatInterval,
            now: now)
    }

    public func execute(
        _ request: ProcessPostCaptureJobsRequest
    ) async -> ProcessPostCaptureJobsResult {
        var processedJobCount = 0
        var changed = false
        var issues: [PostCaptureProcessingIssue] = []
        while !Task.isCancelled {
            let job: ProcessingJob?
            do {
                job = try await store.claimPostCaptureJob(
                    kinds: Self.supportedKinds,
                    owner: request.owner,
                    leaseDuration: leaseDuration,
                    at: now())
            } catch {
                issues.append(PostCaptureProcessingIssue(
                    stage: .claim,
                    message: error.localizedDescription))
                break
            }
            guard let job else { break }

            processedJobCount += 1
            let execution = await execute(job, request: request)
            changed = changed || execution.changed
            if let issue = execution.issue { issues.append(issue) }
        }
        return ProcessPostCaptureJobsResult(
            processedJobCount: processedJobCount,
            durableStateChanged: changed,
            issues: issues)
    }

    public func nextScheduledDate() async throws -> Date? {
        try await store.nextPostCaptureProcessingDate(
            kinds: Self.supportedKinds,
            after: now())
    }
}

private extension ProcessPostCaptureJobs {
    private func execute(
        _ job: ProcessingJob,
        request: ProcessPostCaptureJobsRequest
    ) async -> (changed: Bool, issue: PostCaptureProcessingIssue?) {
        await request.progress(.started(kind: job.kind, attempt: job.attempt))
        let heartbeat = heartbeatTask(for: job, owner: request.owner)
        defer { heartbeat.cancel() }

        do {
            try await executeOwnedJob(job, owner: request.owner)
            await request.progress(.finished(
                kind: job.kind,
                attempt: job.attempt,
                outcome: .succeeded,
                durableStateChanged: true))
            return (true, nil)
        } catch is CancellationError {
            await request.progress(.finished(
                kind: job.kind,
                attempt: job.attempt,
                outcome: .cancelled,
                durableStateChanged: false))
            return (false, nil)
        } catch let error as StorageError where error.isPostCaptureLeaseLoss {
            await request.progress(.finished(
                kind: job.kind,
                attempt: job.attempt,
                outcome: .leaseLost,
                durableStateChanged: false))
            return (false, nil)
        } catch {
            let preservation = await preserveFailure(
                error,
                for: job,
                owner: request.owner)
            await request.progress(.finished(
                kind: job.kind,
                attempt: job.attempt,
                outcome: .failed,
                durableStateChanged: preservation.changed))
            return preservation
        }
    }

    private func executeOwnedJob(_ job: ProcessingJob, owner: String) async throws {
        switch job.kind {
        case .transcription:
            try await processTranscription(job, owner: owner)
        case .diarization:
            try await processDiarization(job, owner: owner)
        case .summary:
            try await processSummary(job, owner: owner)
        default:
            throw PostCaptureProcessingError.unsupportedKind(job.kind.rawValue)
        }
    }

    private func processTranscription(_ job: ProcessingJob, owner: String) async throws {
        guard let detail = try await store.postCaptureDetail(job.meetingID) else {
            throw PostCaptureProcessingError.meetingUnavailable
        }
        let assets = try await store.postCaptureAudioAssets(job.meetingID)
        guard let fingerprint = InitialTranscriptionOperationFingerprint.compute(
            meetingID: job.meetingID,
            transcriptRevision: detail.meeting.transcriptRevision,
            assets: assets)
        else { throw PostCaptureProcessingError.inputNotReady }
        guard fingerprint == job.inputFingerprint else {
            throw PostCaptureProcessingError.inputSuperseded
        }

        let segments = try await transcriptionSegments(
            assets: assets,
            meetingID: job.meetingID)
        guard !segments.isEmpty else { throw PostCaptureProcessingError.emptyTranscript }
        let attribution = SpeakerAttributor.attribute(
            segments: segments,
            turns: [],
            meetingID: job.meetingID)
        let language = SpokenLanguageDetector.homogeneousLanguage(in: attribution.segments)
        let voiceprint = await audio.currentPostCaptureVoiceprint()
        guard let diarization = DiarizationOperationFingerprint.request(
            meetingID: job.meetingID,
            transcriptRevision: detail.meeting.transcriptRevision + 1,
            segments: attribution.segments,
            systemAsset: Self.currentCaptures(in: assets)[.system],
            voiceprint: voiceprint)
        else { throw PostCaptureProcessingError.inputNotReady }

        _ = try await store.publishPostCaptureTranscription(
            job.id,
            owner: owner,
            artifact: TranscriptionArtifact(
                meetingID: job.meetingID,
                inputFingerprint: fingerprint,
                sourceTranscriptRevision: detail.meeting.transcriptRevision,
                language: language,
                speakers: attribution.speakers,
                segments: attribution.segments),
            followUps: [diarization],
            at: now())
        await audio.schedulePostCaptureIdleRelease()
    }

    private func transcriptionSegments(
        assets: [AudioAsset],
        meetingID: MeetingID
    ) async throws -> [TranscriptSegment] {
        let current = Self.currentCaptures(in: assets)
        let hints = TranscriptionHints(meetingID: meetingID)
        var systemSegments: [TranscriptSegment] = []
        if let system = current[.system], Self.isTranscribable(system) {
            systemSegments = try await audio.transcribePostCaptureAudio(
                system,
                channel: .system,
                hints: hints).segments
        }

        var microphoneSegments: [TranscriptSegment] = []
        if let microphone = current[.microphone], Self.isTranscribable(microphone) {
            let raw = try await audio.transcribePostCaptureAudio(
                microphone,
                channel: .microphone,
                hints: hints).segments
            let voiced = raw.filter {
                !TranscriptNoiseFilter.isLikelyNoise(
                    text: $0.text,
                    confidence: $0.confidence)
            }
            microphoneSegments = MicBleedFilter.filter(
                microphone: voiced,
                system: systemSegments)
        }
        return (systemSegments + microphoneSegments).sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func processDiarization(_ job: ProcessingJob, owner: String) async throws {
        guard let detail = try await store.postCaptureDetail(job.meetingID) else {
            throw PostCaptureProcessingError.meetingUnavailable
        }
        guard !detail.segments.isEmpty else {
            throw PostCaptureProcessingError.emptyTranscript
        }

        let assets = try await store.postCaptureAudioAssets(job.meetingID)
        let systemAsset = Self.currentCaptures(in: assets)[.system]
        let voiceprint = await audio.currentPostCaptureVoiceprint()
        guard let fingerprint = DiarizationOperationFingerprint.compute(
            meetingID: job.meetingID,
            transcriptRevision: detail.meeting.transcriptRevision,
            segments: detail.segments,
            systemAsset: systemAsset,
            voiceprint: voiceprint)
        else { throw PostCaptureProcessingError.inputNotReady }
        guard fingerprint == job.inputFingerprint else {
            throw PostCaptureProcessingError.inputSuperseded
        }

        let turns: [SpeakerTurn]
        if let systemAsset, Self.isDiarizable(systemAsset) {
            turns = try await audio.diarizePostCaptureAudio(systemAsset)
        } else {
            turns = []
        }
        let attribution = SpeakerAttributor.attribute(
            segments: detail.segments,
            turns: turns,
            meetingID: job.meetingID)
        let spokenLanguage = SpokenLanguageDetector.homogeneousLanguage(
            in: attribution.segments)
        let followUps = try await summaryFollowUp(
            meeting: detail.meeting,
            segments: attribution.segments,
            speakers: attribution.speakers,
            spokenLanguage: spokenLanguage,
            transcriptRevision: detail.meeting.transcriptRevision + 1)
        let completion = try await store.publishPostCaptureDiarization(
            job.id,
            owner: owner,
            artifact: DiarizationArtifact(
                meetingID: job.meetingID,
                inputFingerprint: fingerprint,
                sourceTranscriptRevision: detail.meeting.transcriptRevision,
                language: spokenLanguage,
                speakers: attribution.speakers,
                segments: attribution.segments),
            followUps: followUps,
            at: now())
        if completion.enqueuedJobs.isEmpty {
            await actions.runPostMeetingAction(for: job.meetingID)
        }
        await audio.schedulePostCaptureIdleRelease()
    }
}

private extension ProcessPostCaptureJobs {
    private func processSummary(_ job: ProcessingJob, owner: String) async throws {
        guard let detail = try await store.postCaptureDetail(job.meetingID) else {
            throw PostCaptureProcessingError.meetingUnavailable
        }
        guard !detail.segments.isEmpty else {
            throw PostCaptureProcessingError.emptyTranscript
        }
        guard let selection = await summaries.postCaptureSummaryProvider() else {
            throw PostCaptureProcessingError.summaryProviderUnavailable
        }
        let request = try await summaryRequest(
            meeting: detail.meeting,
            segments: detail.segments,
            speakers: detail.speakers,
            spokenLanguage: detail.meeting.language)
        let fingerprint = SummaryOperationFingerprint.compute(
            request: request,
            providerID: selection.providerID,
            transcriptRevision: detail.meeting.transcriptRevision)
        guard fingerprint == job.inputFingerprint else {
            throw PostCaptureProcessingError.inputSuperseded
        }

        let attempt = PostCaptureSummaryGenerationAttempt(
            job: job,
            request: request,
            selection: selection,
            sourceTranscriptRevision: detail.meeting.transcriptRevision,
            startedAt: now())
        var draft: SummaryDraft?
        do {
            let generated = try await selection.provider.summarize(request)
            draft = generated
            try await store.publishPostCaptureSummary(
                job.id,
                owner: owner,
                artifact: SummaryArtifact(
                    inputFingerprint: fingerprint,
                    sourceTranscriptRevision: detail.meeting.transcriptRevision,
                    draft: generated,
                    generationRun: attempt.finish(
                        outcome: .succeeded,
                        draft: generated,
                        at: now())),
                at: now())
        } catch {
            let outcome: GenerationRunOutcome = error.isCancelledPostCaptureAttempt
                ? .cancelled
                : .failed
            try? await store.savePostCaptureGenerationRun(
                attempt.finish(outcome: outcome, draft: draft, at: now()))
            throw error
        }
        await actions.runPostMeetingAction(for: job.meetingID)
    }

    private func summaryFollowUp(
        meeting: Meeting,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        spokenLanguage: String?,
        transcriptRevision: Int
    ) async throws -> [ProcessingJobRequest] {
        guard let selection = await summaries.postCaptureSummaryProvider() else {
            return []
        }
        let request = try await summaryRequest(
            meeting: meeting,
            segments: segments,
            speakers: speakers,
            spokenLanguage: spokenLanguage)
        return [ProcessingJobRequest(
            kind: .summary,
            inputFingerprint: SummaryOperationFingerprint.compute(
                request: request,
                providerID: selection.providerID,
                transcriptRevision: transcriptRevision),
            priority: 10,
            maxAttempts: 3)]
    }

    private func summaryRequest(
        meeting: Meeting,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        spokenLanguage: String?
    ) async throws -> SummaryRequest {
        let preferences = await summaries.postCaptureSummaryPreferences(
            spokenLanguage: spokenLanguage)
        return SummaryRequest(
            meetingID: meeting.id,
            segments: segments,
            speakers: speakers,
            recipe: .general,
            targetLanguage: preferences.outputLanguage,
            glossary: preferences.vocabulary,
            contextItems: try await store.postCaptureContextItems(meeting.id))
    }
}

private extension ProcessPostCaptureJobs {
    private func preserveFailure(
        _ error: Error,
        for job: ProcessingJob,
        owner: String
    ) async -> (changed: Bool, issue: PostCaptureProcessingIssue?) {
        do {
            var shouldRunPostMeetingAction = false
            let timestamp = now()
            if error.isSupersededPostCaptureInput {
                try await store.cancelPostCaptureJob(
                    job.id,
                    owner: owner,
                    reason: ProcessingJobFailure(
                        code: "processing.input.superseded",
                        message: error.localizedDescription),
                    at: timestamp)
                shouldRunPostMeetingAction = job.kind == .summary
            } else if job.kind == .summary, job.attempt >= job.maxAttempts {
                try await store.cancelPostCaptureJob(
                    job.id,
                    owner: owner,
                    reason: ProcessingJobFailure(
                        code: "processing.summary.unavailable",
                        message: error.localizedDescription),
                    at: timestamp)
                shouldRunPostMeetingAction = true
            } else {
                try await store.failPostCaptureJob(
                    job.id,
                    owner: owner,
                    failure: ProcessingJobFailure(
                        code: Self.failureCode(for: job.kind),
                        message: error.localizedDescription),
                    retryAt: Self.retryDate(after: job.attempt, from: timestamp),
                    at: timestamp)
            }
            if shouldRunPostMeetingAction {
                await actions.runPostMeetingAction(for: job.meetingID)
            }
            return (true, nil)
        } catch let storageError as StorageError where storageError.isPostCaptureLeaseLoss {
            return (false, nil)
        } catch {
            return (false, PostCaptureProcessingIssue(
                stage: .failurePreservation(job.kind),
                message: error.localizedDescription))
        }
    }

    private func heartbeatTask(for job: ProcessingJob, owner: String) -> Task<Void, Never> {
        let store = store
        let leaseDuration = leaseDuration
        let heartbeatInterval = heartbeatInterval
        let now = now
        return Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: heartbeatInterval)
                    try await store.heartbeatPostCaptureJob(
                        job.id,
                        owner: owner,
                        progress: 0.25,
                        leaseDuration: leaseDuration,
                        at: now())
                } catch {
                    return
                }
            }
        }
    }

    private static func currentCaptures(
        in assets: [AudioAsset]
    ) -> [AudioChannel: AudioAsset] {
        Dictionary(grouping: assets.filter {
            $0.role == .capture && $0.supersededAt == nil && $0.deletedAt == nil
        }, by: \.channel)
        .compactMapValues { candidates in
            candidates.max { $0.updatedAt < $1.updatedAt }
        }
    }

    private static func isTranscribable(_ asset: AudioAsset) -> Bool {
        [.healthy, .clipped].contains(asset.healthStatus)
            && (asset.durationSeconds ?? 0) > 1
    }

    private static func isDiarizable(_ asset: AudioAsset) -> Bool {
        [.healthy, .clipped].contains(asset.healthStatus)
            && (asset.durationSeconds ?? 0) > 1
    }

    private static func retryDate(after attempt: Int, from timestamp: Date) -> Date {
        let delays: [TimeInterval] = [5, 30, 120]
        let index = min(max(attempt - 1, 0), delays.count - 1)
        return timestamp.addingTimeInterval(delays[index])
    }

    private static func failureCode(for kind: ProcessingJobKind) -> String {
        switch kind {
        case .transcription: "processing.transcription.failed"
        case .diarization: "processing.diarization.failed"
        case .summary: "processing.summary.failed"
        default: "processing.worker.failed"
        }
    }
}

private enum PostCaptureProcessingError: LocalizedError {
    case emptyTranscript
    case inputNotReady
    case inputSuperseded
    case meetingUnavailable
    case summaryProviderUnavailable
    case unsupportedKind(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "The captured meeting has no transcript to process."
        case .inputNotReady:
            "The processing input does not have final durable evidence."
        case .inputSuperseded:
            "The processing input changed before execution."
        case .meetingUnavailable:
            "The meeting is no longer available."
        case .summaryProviderUnavailable:
            "No configured local summary provider is currently available."
        case .unsupportedKind(let kind):
            "The process worker does not support \(kind)."
        }
    }
}

private extension Error {
    var isCancelledPostCaptureAttempt: Bool {
        self is CancellationError
            || isSupersededPostCaptureInput
            || (self as? StorageError)?.isPostCaptureLeaseLoss == true
    }

    var isSupersededPostCaptureInput: Bool {
        if let worker = self as? PostCaptureProcessingError,
           case .inputSuperseded = worker {
            return true
        }
        if let storage = self as? StorageError,
           case .processingJobInputChanged = storage {
            return true
        }
        return false
    }
}

private extension StorageError {
    var isPostCaptureLeaseLoss: Bool {
        if case .processingJobLeaseLost = self { return true }
        return false
    }
}
