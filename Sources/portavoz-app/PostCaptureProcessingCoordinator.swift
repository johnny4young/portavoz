import ApplicationKit
import DiarizationKit
import Foundation
import IntelligenceKit
import ModelStoreKit
import OSLog
import PortavozCore
import StorageKit

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
            let telemetry = PostCaptureProcessingTelemetry(services: services)
            let result = await services.processPostCaptureJobs.execute(.init(
                owner: owner
            ) { event in
                await telemetry.receive(event)
            })
            for issue in result.issues {
                PostCaptureProcessingCoordinator.log(issue)
            }
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
            let next = try await services.processPostCaptureJobs.nextScheduledDate()
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

/// Process composition, test-fixture admission, and content-free telemetry for
/// the ApplicationKit durable workflow.
@MainActor
enum PostCaptureProcessingCoordinator {
    private static let logger = Logger(
        subsystem: "app.portavoz.mac", category: "post-capture-processing")

    static func resumeAfterRecovery(services: AppServices) async {
        do {
            if try await seedFixtureIfRequested(services: services) {
                services.requestSpotlightReindex()
            }
        } catch {
            logger.error("Could not prepare processing fixture: \(error.localizedDescription)")
        }
        services.postCaptureProcessing.kick(services: services)
    }

    static func log(_ issue: PostCaptureProcessingIssue) {
        switch issue.stage {
        case .claim:
            logger.error("Could not claim processing work: \(issue.message)")
        case .failurePreservation(let kind):
            logger.error(
                "Could not preserve \(kind.rawValue, privacy: .public) job: \(issue.message)")
        }
    }

    static func logSchedulingFailure(_ error: Error) {
        logger.error("Could not schedule processing wake: \(error.localizedDescription)")
    }

    static func logPostMeetingActionFailure(_ error: Error) {
        logger.error("Could not prepare post-meeting Shortcut: \(error.localizedDescription)")
    }

    private static func seedFixtureIfRequested(
        services: AppServices
    ) async throws -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-seed-processing") else { return false }
        guard arguments.contains("-use-temp-store") else {
            throw FixtureError.requiresTemporaryStore
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
}

@MainActor
private final class PostCaptureProcessingTelemetry {
    private static let signposter = OSSignposter(
        subsystem: "app.portavoz.mac", category: .pointsOfInterest)
    private weak var services: AppServices?
    private var interval: OSSignpostIntervalState?

    init(services: AppServices) {
        self.services = services
    }

    func receive(_ event: PostCaptureProcessingEvent) {
        switch event {
        case .started(let kind, let attempt):
            interval = Self.signposter.beginInterval(
                "Durable processing",
                "kind=\(kind.rawValue, privacy: .public) attempt=\(attempt, privacy: .public)")
        case .finished(_, _, let outcome, let changed):
            if let interval {
                Self.signposter.endInterval(
                    "Durable processing",
                    interval,
                    "outcome=\(outcome.rawValue, privacy: .public)")
                self.interval = nil
            }
            if changed { services?.requestSpotlightReindex() }
        }
    }
}

@MainActor
extension AppServices {
    var processPostCaptureJobs: ProcessPostCaptureJobs {
        ProcessPostCaptureJobs(
            store: store,
            capabilities: AppPostCaptureProcessingCapabilities(services: self))
    }

    func kickPostCaptureProcessing() {
        postCaptureProcessing.kick(services: self)
    }

    func processingPostCaptureSummaryProviderSelection() -> PostCaptureSummaryProviderSelection? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-seed-processing"), arguments.contains("-use-temp-store") {
            return PostCaptureSummaryProviderSelection(
                provider: ProcessingFixtureSummaryProvider(),
                providerID: ProcessingFixtureSummaryProvider.providerID,
                modelID: "fixture-summary",
                modelRevision: "1")
        }

        switch summaryEngine {
        case .ollama:
            guard let model = ollamaModel else { return nil }
            return PostCaptureSummaryProviderSelection(
                provider: OllamaService.summaryProvider(
                    model: model,
                    gateway: dataEgressGateway,
                    consentSource: .summaryEngineSettings),
                providerID: OllamaService.providerID(model: model),
                modelID: model,
                modelRevision: nil)
        case .mlx:
            guard mlxDownloaded else { return nil }
            return PostCaptureSummaryProviderSelection(
                provider: MLXSummaryProvider(
                    modelDirectory: Self.modelDir(ModelCatalog.mlxQwen35)),
                providerID: MLXSummaryProvider.providerID,
                modelID: ModelCatalog.mlxQwen35.id,
                modelRevision: ModelCatalog.mlxQwen35.revision)
        case .appleOnDevice:
            break
        }

        if #available(macOS 26.0, *), foundationModelsCapability.isAvailable {
            return PostCaptureSummaryProviderSelection(
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

private enum FixtureError: LocalizedError {
    case requiresTemporaryStore

    var errorDescription: String? {
        "The processing fixture requires -use-temp-store."
    }
}
