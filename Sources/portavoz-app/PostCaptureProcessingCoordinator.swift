import ApplicationKit
import DiarizationKit
import Foundation
import IntegrationsKit
import IntelligenceKit
import ModelStoreKit
import OSLog
import PortavozCore
import StorageKit
import TranscriptionKit

struct SummaryProviderSelection: Sendable {
    let provider: any SummaryProvider
    let providerID: String
    let modelID: String
    let modelRevision: String?
}

/// Immutable metadata captured immediately before one durable model attempt.
/// Its JSON payloads deliberately exclude meeting content.
struct PostCaptureSummaryGenerationAttempt: Sendable {
    let jobID: ProcessingJobID
    let jobAttempt: Int
    let meetingID: MeetingID
    let providerID: String
    let modelID: String
    let modelRevision: String?
    let inputFingerprint: String
    let recipeID: String
    let outputLanguage: String
    let sourceTranscriptRevision: Int
    let startedAt: Date

    init(
        job: ProcessingJob,
        request: SummaryRequest,
        selection: SummaryProviderSelection,
        sourceTranscriptRevision: Int,
        startedAt: Date = Date()
    ) {
        jobID = job.id
        jobAttempt = job.attempt
        meetingID = job.meetingID
        providerID = selection.providerID
        modelID = selection.modelID
        modelRevision = selection.modelRevision
        inputFingerprint = job.inputFingerprint
        recipeID = request.recipe.id
        outputLanguage = request.targetLanguage
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.startedAt = startedAt
    }

    func finish(
        outcome: GenerationRunOutcome,
        draft: SummaryDraft?,
        at finishedAt: Date = Date(),
        id: GenerationRunID = GenerationRunID()
    ) -> GenerationRun {
        GenerationRun(
            id: id,
            meetingID: meetingID,
            kind: .summary,
            providerID: providerID,
            modelID: modelID,
            modelRevision: modelRevision,
            inputFingerprint: inputFingerprint,
            configJSON: Self.json(Configuration(
                attempt: jobAttempt,
                jobID: jobID.rawValue.uuidString,
                operation: "generate",
                recipeID: recipeID,
                sourceTranscriptRevision: sourceTranscriptRevision,
                workflow: "post-capture")),
            outputLanguage: outputLanguage,
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: outcome,
            metricsJSON: draft.map {
                Self.json(Metrics(
                    actionItemCount: $0.actionItems.count,
                    outputUTF8Bytes: $0.markdown.utf8.count))
            })
    }

    private static func json<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    private struct Configuration: Encodable {
        let attempt: Int
        let jobID: String
        let operation: String
        let recipeID: String
        let sourceTranscriptRevision: Int
        let workflow: String
    }

    private struct Metrics: Encodable {
        let actionItemCount: Int
        let outputUTF8Bytes: Int
    }
}

/// Owns one process-level drain plus one future retry wake. Producers may
/// kick repeatedly; due work is drained serially and SQLite is never polled.
@MainActor
final class PostCaptureProcessingSupervisor {
    private var drainTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var rerunRequested = false
    private var kickGeneration = 0
    private let owner = "post-capture-\(UUID().uuidString.lowercased())"

    func kick(services: AppServices) {
        kickGeneration += 1
        wakeTask?.cancel()
        wakeTask = nil
        guard drainTask == nil else {
            rerunRequested = true
            return
        }

        rerunRequested = false
        drainTask = Task { @MainActor [weak self, weak services] in
            guard let self, let services else { return }
            await PostCaptureProcessingCoordinator.drain(
                services: services, owner: self.owner)
            await self.finishedDrain(services: services)
        }
    }

    private func finishedDrain(services: AppServices) async {
        drainTask = nil
        if rerunRequested {
            rerunRequested = false
            kick(services: services)
            return
        }

        let generation = kickGeneration
        do {
            let next = try await services.store.nextScheduledProcessingDate(
                kinds: PostCaptureProcessingCoordinator.supportedKinds)
            guard generation == kickGeneration, drainTask == nil, let next else { return }
            scheduleWake(at: next, services: services)
        } catch {
            PostCaptureProcessingCoordinator.logSchedulingFailure(error)
        }
    }

    private func scheduleWake(at date: Date, services: AppServices) {
        let delay = max(0, date.timeIntervalSinceNow)
        wakeTask = Task { @MainActor [weak self, weak services] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let services else { return }
            self.wakeTask = nil
            self.kick(services: services)
        }
    }
}

/// Concrete Band 1 worker for durable diarization and summary operations.
/// Capture recovery always runs first; normal Stop atomically admits the first
/// job and hands the remaining work to this process-scoped supervisor.
@MainActor
enum PostCaptureProcessingCoordinator {
    static let supportedKinds: Set<ProcessingJobKind> = [.diarization, .summary]

    private static let logger = Logger(
        subsystem: "app.portavoz.mac", category: "post-capture-processing")
    private static let leaseDuration: TimeInterval = 120
    private static let heartbeatInterval: Duration = .seconds(30)

    static func resumeAfterRecovery(services: AppServices) async {
        do {
            if try await seedFixtureIfRequested(services: services) {
                services.libraryVersion += 1
            }
        } catch {
            logger.error("Could not prepare processing fixture: \(error.localizedDescription)")
        }
        services.postCaptureProcessing.kick(services: services)
    }

    static func drain(services: AppServices, owner: String) async {
        while !Task.isCancelled {
            let job: ProcessingJob?
            do {
                job = try await services.store.claimNextProcessingJob(
                    kinds: supportedKinds,
                    owner: owner,
                    leaseDuration: leaseDuration)
            } catch {
                logger.error("Could not claim processing work: \(error.localizedDescription)")
                return
            }
            guard let job else { return }

            let changed = await execute(job, owner: owner, services: services)
            if changed { services.libraryVersion += 1 }
        }
    }

    static func logSchedulingFailure(_ error: Error) {
        logger.error("Could not schedule processing wake: \(error.localizedDescription)")
    }

    private static func execute(
        _ job: ProcessingJob,
        owner: String,
        services: AppServices
    ) async -> Bool {
        let heartbeat = heartbeatTask(for: job, owner: owner, store: services.store)
        defer { heartbeat.cancel() }

        do {
            switch job.kind {
            case .diarization:
                try await processDiarization(job, owner: owner, services: services)
            case .summary:
                try await processSummary(job, owner: owner, services: services)
            default:
                throw WorkerError.unsupportedKind(job.kind.rawValue)
            }
            return true
        } catch is CancellationError {
            return false
        } catch let error as StorageError where error.isLeaseLoss {
            return false
        } catch {
            return await preserveFailure(
                error, for: job, owner: owner, services: services)
        }
    }

    private static func heartbeatTask(
        for job: ProcessingJob,
        owner: String,
        store: MeetingStore
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: heartbeatInterval)
                    _ = try await store.heartbeatProcessingJob(
                        job.id,
                        owner: owner,
                        progress: 0.25,
                        leaseDuration: leaseDuration)
                } catch {
                    return
                }
            }
        }
    }

    private static func processDiarization(
        _ job: ProcessingJob,
        owner: String,
        services: AppServices
    ) async throws {
        guard let detail = try await services.store.detail(job.meetingID) else {
            throw WorkerError.meetingUnavailable
        }
        guard !detail.segments.isEmpty else { throw WorkerError.emptyTranscript }

        let assets = try await services.store.audioAssets(for: job.meetingID)
        let systemAsset = currentSystemCapture(in: assets)
        let voiceprint = await currentVoiceprint()
        guard let fingerprint = DiarizationOperationFingerprint.compute(
            meetingID: job.meetingID,
            transcriptRevision: detail.meeting.transcriptRevision,
            segments: detail.segments,
            systemAsset: systemAsset,
            voiceprint: voiceprint)
        else { throw WorkerError.inputNotReady }
        guard fingerprint == job.inputFingerprint else {
            throw WorkerError.inputSuperseded
        }

        let turns = try await speakerTurns(
            from: systemAsset, services: services)
        let attribution = SpeakerAttributor.attribute(
            segments: detail.segments,
            turns: turns,
            meetingID: job.meetingID)
        let spokenLanguage = SpokenLanguageDetector.homogeneousLanguage(
            in: attribution.segments)
        let nextRevision = detail.meeting.transcriptRevision + 1
        let followUps = try await summaryFollowUp(
            meeting: detail.meeting,
            segments: attribution.segments,
            speakers: attribution.speakers,
            spokenLanguage: spokenLanguage,
            transcriptRevision: nextRevision,
            services: services)

        let completion = try await services.store.completeDiarizationJob(
            job.id,
            owner: owner,
            artifact: DiarizationArtifact(
                meetingID: job.meetingID,
                inputFingerprint: fingerprint,
                sourceTranscriptRevision: detail.meeting.transcriptRevision,
                language: spokenLanguage,
                speakers: attribution.speakers,
                segments: attribution.segments),
            enqueue: followUps)
        if completion.enqueuedJobs.isEmpty {
            await runPostMeetingShortcut(for: job.meetingID, services: services)
        }
        services.scheduleRecordingEnginesRelease()
    }

    private static func processSummary(
        _ job: ProcessingJob,
        owner: String,
        services: AppServices
    ) async throws {
        guard let detail = try await services.store.detail(job.meetingID) else {
            throw WorkerError.meetingUnavailable
        }
        guard !detail.segments.isEmpty else { throw WorkerError.emptyTranscript }
        guard let selection = services.processingSummaryProviderSelection() else {
            throw WorkerError.summaryProviderUnavailable
        }

        let request = try await summaryRequest(
            meeting: detail.meeting,
            segments: detail.segments,
            speakers: detail.speakers,
            spokenLanguage: detail.meeting.language,
            services: services)
        let fingerprint = SummaryOperationFingerprint.compute(
            request: request,
            providerID: selection.providerID,
            transcriptRevision: detail.meeting.transcriptRevision)
        guard fingerprint == job.inputFingerprint else {
            throw WorkerError.inputSuperseded
        }

        let attempt = PostCaptureSummaryGenerationAttempt(
            job: job,
            request: request,
            selection: selection,
            sourceTranscriptRevision: detail.meeting.transcriptRevision)
        var generatedDraft: SummaryDraft?
        do {
            let draft = try await selection.provider.summarize(request)
            generatedDraft = draft
            _ = try await services.store.completeSummaryJob(
                job.id,
                owner: owner,
                artifact: SummaryArtifact(
                    inputFingerprint: fingerprint,
                    sourceTranscriptRevision: detail.meeting.transcriptRevision,
                    draft: draft,
                    generationRun: attempt.finish(
                        outcome: .succeeded,
                        draft: draft)))
        } catch {
            let outcome: GenerationRunOutcome = error.isCancelledGenerationAttempt
                ? .cancelled
                : .failed
            // Failure provenance is best effort so diagnostics cannot mask
            // the durable worker's existing lease/retry/cancellation policy.
            try? await services.store.saveGenerationRun(
                attempt.finish(outcome: outcome, draft: generatedDraft))
            throw error
        }
        await runPostMeetingShortcut(for: job.meetingID, services: services)
    }

    private static func speakerTurns(
        from asset: AudioAsset?,
        services: AppServices
    ) async throws -> [SpeakerTurn] {
        guard let asset,
            [.healthy, .silent, .clipped].contains(asset.healthStatus),
            (asset.durationSeconds ?? 0) > 1
        else { return [] }

        let url = RecordingsLocation.shared.resolve(asset.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkerError.audioUnavailable
        }
        guard asset.healthStatus != .silent else { return [] }

        // Preserve the released best-effort attribution semantics: model
        // preparation/inference failure degrades to an unattributed system
        // channel, while missing finalized audio remains a durable failure.
        try? await services.loadEnginesIfNeeded()
        guard let diarizer = services.diarizer else { return [] }
        return (try? await diarizer.diarizeFile(at: url)) ?? []
    }

    private static func summaryFollowUp(
        meeting: Meeting,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        spokenLanguage: String?,
        transcriptRevision: Int,
        services: AppServices
    ) async throws -> [ProcessingJobRequest] {
        guard let selection = services.processingSummaryProviderSelection() else { return [] }
        let request = try await summaryRequest(
            meeting: meeting,
            segments: segments,
            speakers: speakers,
            spokenLanguage: spokenLanguage,
            services: services)
        let fingerprint = SummaryOperationFingerprint.compute(
            request: request,
            providerID: selection.providerID,
            transcriptRevision: transcriptRevision)
        return [ProcessingJobRequest(
            kind: .summary,
            inputFingerprint: fingerprint,
            priority: 10,
            maxAttempts: 3)]
    }

    private static func summaryRequest(
        meeting: Meeting,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        spokenLanguage: String?,
        services: AppServices
    ) async throws -> SummaryRequest {
        let language = MeetingLanguagePreferences.resolvedSummaryLanguage(
            spokenLanguage: spokenLanguage).identifier
        let vocabulary = VocabularyPrompt.parse(
            UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
        return SummaryRequest(
            meetingID: meeting.id,
            segments: segments,
            speakers: speakers,
            recipe: .general,
            targetLanguage: language,
            glossary: vocabulary,
            contextItems: try await services.store.contextItems(for: meeting.id))
    }

    private static func preserveFailure(
        _ error: Error,
        for job: ProcessingJob,
        owner: String,
        services: AppServices
    ) async -> Bool {
        do {
            var shouldRunShortcut = false
            if error.isSupersededProcessingInput {
                _ = try await services.store.cancelProcessingJob(
                    job.id,
                    owner: owner,
                    reason: ProcessingJobFailure(
                        code: "processing.input.superseded",
                        message: error.localizedDescription))
                shouldRunShortcut = job.kind == .summary
            } else if job.kind == .summary, job.attempt >= job.maxAttempts {
                _ = try await services.store.cancelProcessingJob(
                    job.id,
                    owner: owner,
                    reason: ProcessingJobFailure(
                        code: "processing.summary.unavailable",
                        message: error.localizedDescription))
                shouldRunShortcut = true
            } else {
                _ = try await services.store.failProcessingJob(
                    job.id,
                    owner: owner,
                    failure: ProcessingJobFailure(
                        code: failureCode(for: job.kind),
                        message: error.localizedDescription),
                    retryAt: retryDate(after: job.attempt))
            }
            if shouldRunShortcut {
                await runPostMeetingShortcut(for: job.meetingID, services: services)
            }
            return true
        } catch let storageError as StorageError where storageError.isLeaseLoss {
            return false
        } catch {
            logger.error(
                "Could not preserve job \(job.id.rawValue.uuidString): \(error.localizedDescription)")
            return false
        }
    }

    private static func retryDate(after attempt: Int) -> Date {
        let delays: [TimeInterval] = [5, 30, 120]
        let index = min(max(attempt - 1, 0), delays.count - 1)
        return Date().addingTimeInterval(delays[index])
    }

    private static func failureCode(for kind: ProcessingJobKind) -> String {
        switch kind {
        case .diarization: "processing.diarization.failed"
        case .summary: "processing.summary.failed"
        default: "processing.worker.failed"
        }
    }

    private static func currentSystemCapture(in assets: [AudioAsset]) -> AudioAsset? {
        assets
            .filter {
                $0.channel == .system && $0.role == .capture
                    && $0.supersededAt == nil && $0.deletedAt == nil
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private static func currentVoiceprint() async -> Voiceprint? {
        guard !isSafeProcessingFixture else { return nil }
        return await Task.detached(priority: .utility) {
            try? VoiceprintStore().load()
        }.value
    }

    /// Preserves M16 after Stop becomes asynchronous. Disposable stores never
    /// invoke a real user Shortcut, even if the host defaults contain one.
    private static func runPostMeetingShortcut(
        for meetingID: MeetingID,
        services: AppServices
    ) async {
        guard !ProcessInfo.processInfo.arguments.contains("-use-temp-store") else { return }
        do {
            guard let detail = try await services.store.detail(meetingID) else { return }
            let summary = try await services.store.summary(meetingID)?.draft
            PostMeetingShortcut.runIfConfigured(markdown: MeetingExporter.markdown(
                meeting: detail.meeting,
                speakers: detail.speakers,
                segments: detail.segments,
                summary: summary))
        } catch {
            logger.error(
                "Could not prepare post-meeting Shortcut: \(error.localizedDescription)")
        }
    }

    private static func seedFixtureIfRequested(
        services: AppServices
    ) async throws -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-seed-processing") else { return false }
        guard arguments.contains("-use-temp-store") else {
            throw WorkerError.fixtureRequiresTemporaryStore
        }
        guard try await services.store.meetings().isEmpty else { return false }

        let meetingID = MeetingID(rawValue: UUID(
            uuidString: "51515151-5151-5151-5151-515151515151")!)
        let meeting = Meeting(
            id: meetingID,
            title: "Durable processing recovery",
            startedAt: Date(timeIntervalSince1970: 1_783_699_200),
            endedAt: Date(timeIntervalSince1970: 1_783_699_260),
            language: "es",
            lifecycleState: .captured)
        let provisional = TranscriptSegment(
            id: UUID(uuidString: "61616161-6161-6161-6161-616161616161")!,
            meetingID: meetingID,
            channel: .microphone,
            text: "El procesamiento durable conserva este texto.",
            language: "es",
            startTime: 0,
            endTime: 4,
            confidence: 0.95,
            isFinal: true)
        let attribution = SpeakerAttributor.attribute(
            segments: [provisional], turns: [], meetingID: meetingID)

        try await services.store.save(meeting)
        try await services.store.save(attribution.speakers)
        try await services.store.save(attribution.segments)
        let request = try StopRecordingJobFactory.initialDiarizationRequest(
            meeting: meeting,
            segments: attribution.segments,
            assets: [],
            voiceprint: nil)
        _ = try await services.store.enqueueProcessingJobs(
            for: meetingID, requests: [request])
        return true
    }

    private static var isSafeProcessingFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-seed-processing")
            && arguments.contains("-use-temp-store")
    }
}

@MainActor
extension AppServices {
    func kickPostCaptureProcessing() {
        postCaptureProcessing.kick(services: self)
    }

    func processingSummaryProviderSelection() -> SummaryProviderSelection? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-seed-processing"), arguments.contains("-use-temp-store") {
            return SummaryProviderSelection(
                provider: ProcessingFixtureSummaryProvider(),
                providerID: ProcessingFixtureSummaryProvider.providerID,
                modelID: "fixture-summary",
                modelRevision: "1")
        }

        switch summaryEngine {
        case .ollama:
            if let model = ollamaModel {
                return SummaryProviderSelection(
                    provider: OllamaService.summaryProvider(model: model),
                    providerID: OllamaService.providerID(model: model),
                    modelID: model,
                    modelRevision: nil)
            }
        case .mlx:
            if mlxDownloaded {
                return SummaryProviderSelection(
                    provider: MLXSummaryProvider(
                        modelDirectory: Self.modelDir(ModelCatalog.mlxQwen35)),
                    providerID: MLXSummaryProvider.providerID,
                    modelID: ModelCatalog.mlxQwen35.id,
                    modelRevision: ModelCatalog.mlxQwen35.revision)
            }
        case .appleOnDevice:
            break
        }

        if #available(macOS 26.0, *),
            FoundationModelSummaryProvider.unavailabilityReason() == nil {
            return SummaryProviderSelection(
                provider: FoundationModelSummaryProvider(),
                providerID: FoundationModelSummaryProvider.providerID,
                modelID: "system-language-model",
                modelRevision: nil)
        }
        return nil
    }
}

private struct ProcessingFixtureSummaryProvider: SummaryProvider {
    static let providerID = "uitest-summary"

    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        SummaryDraft(
            meetingID: request.meetingID,
            recipeID: request.recipe.id,
            language: request.targetLanguage,
            markdown: """
                Durable processing finished.

                ## Result
                - The original transcript survived the resumed worker.
                """,
            actionItems: [],
            fingerprint: SummaryFingerprint.compute(
                request: request, providerID: Self.providerID))
    }
}

private enum WorkerError: LocalizedError {
    case audioUnavailable
    case emptyTranscript
    case fixtureRequiresTemporaryStore
    case inputNotReady
    case inputSuperseded
    case meetingUnavailable
    case summaryProviderUnavailable
    case unsupportedKind(String)

    var errorDescription: String? {
        switch self {
        case .audioUnavailable:
            "The finalized system audio is no longer available."
        case .emptyTranscript:
            "The captured meeting has no transcript to process."
        case .fixtureRequiresTemporaryStore:
            "The processing fixture requires -use-temp-store."
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
    var isCancelledGenerationAttempt: Bool {
        self is CancellationError
            || isSupersededProcessingInput
            || (self as? StorageError)?.isLeaseLoss == true
    }

    var isSupersededProcessingInput: Bool {
        if let worker = self as? WorkerError, case .inputSuperseded = worker {
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
    var isLeaseLoss: Bool {
        if case .processingJobLeaseLost = self { return true }
        return false
    }
}
