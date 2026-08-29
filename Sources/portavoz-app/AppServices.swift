import ApplicationKit
import DiarizationKit
import Foundation
import IntegrationsKit
import IntelligenceKit
import ModelStoreKit
import Observation
import PlatformKit
import PortavozCore
import StorageKit
import SwiftUI
import TranscriptionKit

/// A citation seek is scoped to one meeting and carries identity so repeated
/// requests for the same timestamp still publish an observable change.
struct MeetingSeekRequest: Equatable {
    let id = UUID()
    let meetingID: MeetingID
    let timestamp: TimeInterval
}

/// Storage isolation is selected once at process composition. UI automation
/// gets an empty model root as well as a disposable meeting database. The
/// hidden benchmarks that need Portavoz-managed models keep only the database
/// disposable and reuse the normal verified model cache so repeated Release
/// samples do not include a fresh model installation. OS-model-only Ask and
/// standalone indexing keep both Portavoz stores disposable.
struct AppStorageIsolationPolicy: Equatable {
    let usesTemporaryMeetingStore: Bool
    let usesTemporaryModelStore: Bool
    let usesTemporarySensitiveStore: Bool
    let meetingStoreURL: URL
    let simulatesDatabaseOpenFailure: Bool

    init(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        usesTemporaryMeetingStore = arguments.contains("-use-temp-store")
        usesTemporarySensitiveStore = usesTemporaryMeetingStore
        let reusesVerifiedModels = arguments.contains("--bench-record")
            || arguments.contains("--bench-resource-prepare-refine")
            || arguments.contains("--bench-resource-refine")
            || arguments.contains("--bench-resource-summary")
        usesTemporaryModelStore =
            usesTemporaryMeetingStore && !reusesVerifiedModels
        if usesTemporaryMeetingStore {
            meetingStoreURL = environment["PORTAVOZ_UI_TEST_DATABASE_PATH"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                    "portavoz-uitest-\(UUID().uuidString).sqlite")
        } else {
            meetingStoreURL = MeetingStore.defaultDatabaseURL
        }
        simulatesDatabaseOpenFailure = usesTemporaryMeetingStore
            && arguments.contains("-simulate-database-open-failure")
    }
}

/// Deterministic XCUITest-only failure injected after a disposable SQLite
/// authority has been materialized. Production launches can never select it.
private struct AppSimulatedDatabaseOpenFailure: Error {}

/// Composition root: the database, the ML engines (loaded once, shared by
/// every recording), and cross-view invalidation. Lives on the main actor;
/// the engines themselves do their work off it.
@MainActor
@Observable
final class AppServices {
    enum ModelsState: Equatable {
        case unknown
        case downloading(String)
        case ready
        case failed(String)
    }

    /// `~/Library/Application Support/Portavoz`
    static var supportRoot: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support")
        return base.appendingPathComponent("Portavoz", isDirectory: true)
    }

    /// Meeting audio lives under here; the database only ever stores the
    /// path relative to it (D4). The user can point it elsewhere in
    /// Settings → Recordings; reads should go through
    /// `RecordingsLocation.shared.resolve(_:)` for the old-root fallback.
    static var audioRoot: URL { RecordingsLocation.shared.currentRoot() }

    let store: MeetingStore
    /// One process-owned permission/reconciliation model schedules only
    /// confirmed due commitments and coalesces mutation bursts without a
    /// polling timer.
    let commitmentReminders: CommitmentReminderModel
    /// One process-wide verified model store and lifecycle. Disposable
    /// automation receives its own empty root and never inspects host models.
    @ObservationIgnored let modelStore: ModelStore
    @ObservationIgnored let modelLifecycle: VerifiedModelLifecycle
    /// One process-owned, content-free view of heavyweight runtime lifecycle.
    /// Capability owners submit complete family transitions one adapter at a
    /// time; all five heavyweight families now use this exact owner.
    @ObservationIgnored let modelResidencyLedger =
        AppModelResidencyLedger()
    /// Content-free workload spans are installed once at the composition root.
    @ObservationIgnored let workloadTelemetry: ResourceWorkloadTelemetry
    /// The narrow platform bridge for pressure-driven idle model release.
    @ObservationIgnored var resourcePressureMonitor: AppResourcePressureMonitor?
    /// Content-free recording phase readable from non-MainActor residency
    /// callbacks without reaching into the observable controller.
    @ObservationIgnored let resourceCaptureState = AppResourceCaptureState()
    @ObservationIgnored let microphonePermissions: MicrophonePermissionClient
    /// Shared async credential workflow for Settings and publishing surfaces.
    @ObservationIgnored let secrets: ManageSecrets
    /// Encrypted biometric stores share the same device-only Keychain adapter.
    @ObservationIgnored let voiceprintStore: VoiceprintStore
    @ObservationIgnored let voiceGallery: VoiceGallery
    /// One process-wide decision prevents competing welcome sheets when macOS
    /// restores more than one main window.
    let firstRun: FirstRunModel
    /// One process-wide truthful receipt is shared by every Settings window.
    let localDataLedger: LocalDataLedgerModel
    /// One content-free projection receives typed events from the five
    /// existing background owners. It never polls or schedules work itself.
    let backgroundWork: BackgroundWorkCenterModel
    /// One Ask application workflow feeds every macOS Ask presentation model.
    @ObservationIgnored let askClient: AppAskModelClient
    /// Pull-based live interview answers reuse the exact selected Ask engine
    /// but keep their bounded recording evidence outside library retrieval.
    @ObservationIgnored let assistInterviewQuestion: AssistInterviewQuestion
    /// Ask and Library share one governed Apple contextual-embedding runtime.
    @ObservationIgnored let semanticEmbeddingRuntime:
        AppSemanticEmbeddingRuntime
    /// One process-scoped Settings owner for the only product action allowed
    /// to request Apple's OS-managed semantic assets.
    @ObservationIgnored lazy var semanticSearchPreparation =
        SemanticSearchPreparationModel(
            client: AppSemanticSearchPreparationClient(services: self))
    /// Background maintenance owns product corpus writes and coalesces them
    /// through one semantic-index flight.
    @ObservationIgnored let semanticIndexingCoordinator:
        SemanticCorpusIndexingCoordinator
    /// Signal-driven process owner resumes durable semantic backfill without
    /// polling SQLite or making a SwiftUI view responsible for maintenance.
    @ObservationIgnored let semanticIndexingSupervisor:
        SemanticCorpusIndexingSupervisor
    /// Signal-driven owner for the disposable typed meeting-memory graph.
    /// It shares durable maintenance semantics but never borrows a model.
    @ObservationIgnored let memoryGraphProjectionSupervisor:
        MeetingMemoryGraphProjectionSupervisor
    /// One process-shared Library lane augments exact search without
    /// downloading assets as a side effect of typing.
    @ObservationIgnored let librarySemanticSearch: LocalLibrarySemanticSearch
    /// Upcoming-meeting preparation shares Ask retrieval and returns only
    /// storage-independent ApplicationKit values.
    @ObservationIgnored let meetingBriefUseCase: PrepareMeetingBrief
    /// One no-prompt calendar boundary supplies opaque event references to
    /// Library, reminders, and the resident brief proposal.
    @ObservationIgnored let upcomingEventSource: AppUpcomingEventSource
    /// One process-owned Reminders boundary. Disposable automation always
    /// receives an in-memory fake and can never reach host TCC or EventKit.
    @ObservationIgnored let reminderDraftPlatform:
        any AppReminderDraftPlatform
    /// Process-owned local-draft handoff for the menu-bar brief Skill.
    @ObservationIgnored let meetingBriefSkillDelivery:
        AppMeetingBriefSkillDelivery
    /// One process-owned recap delivery boundary keeps a failed skill attempt
    /// retryable under the same adapter and durable proposal claim.
    @ObservationIgnored let recapSkillDelivery: any RecapDraftDelivering
    /// The only email effect is a review-first system-composer handoff. UI
    /// automation receives an inert recorder and cannot open the host client.
    @ObservationIgnored let emailRecapDraftDelivery:
        any EmailRecapDraftDelivering
    /// Retained only as a composition decision. Disposable automation must
    /// never resolve a real GitHub credential or transport.
    @ObservationIgnored let usesTemporaryMeetingStore: Bool
    /// Whole-library export state outlives Settings windows so closing a pane
    /// cannot cancel publication or start a competing backup.
    let libraryMarkdownBackup: LibraryMarkdownBackupModel
    /// Process-scoped opt-in CloudKit policy and wakeup owner. The XCUITest
    /// composition is an explicit in-memory fake and production construction
    /// remains CKContainer-free until prior consent or Enable.
    let meetingSync: MeetingSyncModel
    var dataEgressGateway: URLSessionDataEgressGateway {
        URLSessionDataEgressGateway(receiptRecorder: store)
    }
    var modelsState: ModelsState = .unknown
    var transcriber: ParakeetEngine?
    @ObservationIgnored var liveSpeechRuntimeLoad: LiveSpeechRuntimeLoad?
    var diarizationRuntime: PyannoteDiarizationRuntime?
    @ObservationIgnored var diarizationRuntimeLoad: DiarizationRuntimeLoad?
    var enginesIdleGeneration = 0
    var whisper: WhisperEngine?
    var whisperVariantID: String?
    @ObservationIgnored var whisperRuntimeLoad: WhisperRuntimeLoad?
    var whisperPreparationState: WhisperPreparationState = .idle
    @ObservationIgnored var whisperPreparedModel: WhisperEngine.PreparedModel?
    @ObservationIgnored var whisperPreparation: WhisperPreparation?
    @ObservationIgnored var whisperBackgroundPreparation: Task<Void, Never>?
    @ObservationIgnored var whisperProgressObservers: [UUID: WhisperPreparationObserver] = [:]
    var whisperIdleGeneration = 0
    private(set) var mlxDownloaded = false
    /// IntelligenceKit owns container mechanics; composition owns the one
    /// process runtime and every residency transition around it.
    @ObservationIgnored let mlxSummaryRuntime = MLXSummaryRuntime()
    @ObservationIgnored var mlxRuntimeLoad: MLXRuntimeLoad?
    var mlxRuntimeDirectoryKey: String?
    var mlxIdleGeneration = 0

    /// Process-scoped, coalescing reconciliation for the protected local
    /// Spotlight index. It is deliberately not owned by a SwiftUI window.
    @ObservationIgnored let spotlightIndexer: SpotlightIndexer
    /// Navigation requested from OUTSIDE the window hierarchy (the
    /// pre-meeting banner): ContentView observes it, applies it to its
    /// route, and clears it.
    var pendingRoute: Route?
    /// A feature can open the native Settings scene at the exact recovery
    /// pane. Settings consumes this one-shot route whether its window is new
    /// or already open.
    var pendingSettingsCategory: SettingsCategory?
    /// Quality re-passes keyed by meeting — they outlive the detail view,
    /// so navigating away never loses a draft (field bug, Jul 10).
    let refines = RefineService()
    /// One serial utility lane for file transcription. Live streams bypass it
    /// by design, so a new recording always wins ANE scheduling (D7).
    let transcriptionScheduler: TranscriptionScheduler
    /// Process-scoped ownership of the durable post-capture worker and its
    /// single scheduled retry wake. The supervisor deduplicates launch and
    /// producer kicks without polling SQLite.
    let postCaptureProcessing: PostCaptureProcessingSupervisor
    /// System-wide dictation (⌥⌘D): lives here so the hotkey and its
    /// session survive any window coming and going.
    let dictation = DictationController()
    /// THE recording session (one at a time by design): shared so the
    /// recording view, the HUD and the menu bar all observe the same one,
    /// and navigating away can never orphan a live session.
    let recording = RecordingController()
    /// ⌘K palette (design system 6a-1): floats over any view; state and owned
    /// tasks live here so it works safely with the library window closed.
    let palette: CommandPaletteController
    /// One-shot, meeting-scoped seek consumed only by its destination detail.
    /// Existing details observe it too, so navigating to the already-open
    /// meeting cannot strand the request waiting for a route reconstruction.
    var pendingMeetingSeek: MeetingSeekRequest?
    /// The meeting that just finished recording — the detail view shows the
    /// post-meeting mirror (6a-2) once for it, if the setting is on and it
    /// qualifies. One-shot: consumed on show.
    var justRecorded: MeetingID?

    func requestMeetingSeek(for citation: AskCitation) {
        requestMeetingSeek(
            meetingID: citation.meetingID,
            timestamp: citation.timestamp)
    }

    func requestMeetingSeek(
        meetingID: MeetingID,
        timestamp: TimeInterval
    ) {
        pendingMeetingSeek = MeetingSeekRequest(
            meetingID: meetingID,
            timestamp: timestamp)
    }

    /// The user's average talk-share over their recent meetings (excluding
    /// one) — the mirror compares "% you spoke" against this. Nil when there
    /// isn't enough history. Reuses the aggregate voice-mix query.
    func averageMyShare(excluding meetingID: MeetingID, recent: Int = 10) async -> Double? {
        guard let meetings = try? await store.meetings() else { return nil }
        let recentIDs = meetings.filter { $0.id != meetingID }.prefix(recent).map(\.id)
        guard !recentIDs.isEmpty,
            let mixes = try? await store.voiceMixes(for: Array(recentIDs))
        else { return nil }
        let shares = mixes.values.compactMap { $0.first(where: \.isMe)?.fraction }
        guard !shares.isEmpty else { return nil }
        return shares.reduce(0, +) / Double(shares.count)
    }

    init( // swiftlint:disable:this function_body_length
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storagePolicy: AppStorageIsolationPolicy? = nil
    ) throws {
        let storagePolicy = Self.prepareStoragePolicy(
            arguments: arguments,
            environment: environment,
            override: storagePolicy)
        let usesTemporaryStore = storagePolicy.usesTemporaryMeetingStore
        usesTemporaryMeetingStore = usesTemporaryStore
        // Open the authority before constructing process runtimes or installing
        // global telemetry. A failed retry therefore leaves no half-composed
        // service graph, model task, sensitive store, or background owner.
        store = try Self.makeMeetingStore(storagePolicy: storagePolicy)
        let backgroundWork = BackgroundWorkCenterModel()
        self.backgroundWork = backgroundWork
        postCaptureProcessing = PostCaptureProcessingSupervisor(
            backgroundWork: backgroundWork)
        let workloadTelemetry = AppResourceWorkloadTelemetry.shared.telemetry
        self.workloadTelemetry = workloadTelemetry
        transcriptionScheduler = Self.makeTranscriptionScheduler(telemetry: workloadTelemetry)
        (modelStore, modelLifecycle) = Self.makeModelServices(
            usesTemporaryStore: storagePolicy.usesTemporaryModelStore)
        semanticEmbeddingRuntime = Self.makeSemanticEmbeddingRuntime(
            arguments: arguments, usesTemporaryStore: usesTemporaryStore,
            residency: modelResidencyLedger, telemetry: workloadTelemetry)
        let sensitiveStorage = Self.makeSensitiveStorage(usesTemporaryStore: storagePolicy.usesTemporarySensitiveStore)
        microphonePermissions = MicrophonePermissionClient()
        secrets = ManageSecrets(storage: sensitiveStorage.secrets)
        voiceprintStore = sensitiveStorage.voiceprintStore
        voiceGallery = sensitiveStorage.voiceGallery
        commitmentReminders = Self.makeCommitmentReminderModel(
            store: store, usesTemporaryStore: usesTemporaryMeetingStore)
        let selectedAskAnswering = AppSelectedAskMeetingAnswering()
        assistInterviewQuestion = Self.makeInterviewAssist(
            arguments: arguments, selectedAnswering: selectedAskAnswering)
        let semanticSearch = Self.makeSemanticSearchComposition(
            store: store, usesTemporaryStore: usesTemporaryMeetingStore, semanticRuntime: semanticEmbeddingRuntime,
            selectedAnswering: selectedAskAnswering, telemetry: workloadTelemetry,
            backgroundWork: AppBackgroundWorkComposition(
                model: backgroundWork,
                captureState: resourceCaptureState,
                enablesFixture: arguments.contains("-enable-background-work-fixture")))
        semanticIndexingCoordinator = semanticSearch.coordinator
        semanticIndexingSupervisor = semanticSearch.background
        memoryGraphProjectionSupervisor = semanticSearch.memoryGraphBackground
        librarySemanticSearch = semanticSearch.library
        let askUseCase = semanticSearch.ask
        firstRun = Self.makeFirstRunModel(store: store)
        localDataLedger = Self.makeLocalDataLedgerModel(
            store: store, usesTemporaryStore: usesTemporaryStore,
            voiceGallery: voiceGallery, voiceprintStore: voiceprintStore)
        askClient = Self.makeAskModelClient(composition: semanticSearch, store: store)
        recapSkillDelivery = Self.makeRecapSkillDelivery(arguments: arguments, usesTemporaryStore: usesTemporaryStore)
        emailRecapDraftDelivery = Self.makeEmailRecapDraftDelivery(usesTemporaryStore: usesTemporaryStore)
        upcomingEventSource = AppUpcomingEventSource(arguments: arguments, usesTemporaryStore: usesTemporaryStore)
        reminderDraftPlatform = Self.makeReminderDraftPlatform(usesTemporaryStore: usesTemporaryStore)
        meetingBriefSkillDelivery = AppMeetingBriefSkillDelivery()
        meetingBriefUseCase = PrepareMeetingBrief(
            ask: askUseCase,
            library: AppMeetingBriefLibraryReader(store: store),
            synthesizer: AppOnDeviceMeetingBriefSynthesizer())
        palette = CommandPaletteController(model: CommandPaletteModel(client: askClient))
        meetingSync = Self.makeMeetingSyncModel(
            store: store, usesTemporaryStore: usesTemporaryStore,
            telemetry: workloadTelemetry, captureState: resourceCaptureState)
        libraryMarkdownBackup = Self.makeLibraryMarkdownBackupModel(
            store: store, captureState: resourceCaptureState, usesTemporaryStore: usesTemporaryStore)
        spotlightIndexer = SpotlightIndexer(
            store: store,
            enabled: !usesTemporaryStore && SpotlightIndexer.indexingAvailable,
            telemetry: workloadTelemetry,
            statusChanged: { [weak backgroundWork] status, retryAt in
                await backgroundWork?.receiveSpotlight(
                    status,
                    retryAt: retryAt)
            })
        installSelectedAskResolver(on: selectedAskAnswering)
        scheduleInitialReadinessRefresh()
    }

    private static func makeTranscriptionScheduler(
        telemetry: ResourceWorkloadTelemetry
    ) -> TranscriptionScheduler {
        IntelligenceScheduler.installSharedTelemetry(telemetry)
        return TranscriptionScheduler(telemetry: telemetry)
    }

    private static func prepareStoragePolicy(
        arguments: [String],
        environment: [String: String],
        override: AppStorageIsolationPolicy?
    ) -> AppStorageIsolationPolicy {
        // The UI-test host has its own bundle identity, but volatile
        // per-launch preferences must land before any service reads defaults.
        UITestDefaults.installIfNeeded(
            arguments: arguments,
            environment: environment)
        return override ?? AppStorageIsolationPolicy(
            arguments: arguments,
            environment: environment)
    }

    private func scheduleInitialReadinessRefresh() {
        Task { @MainActor [weak self] in
            await self?.refreshMLXReadiness()
        }
    }

    private static func makeLocalDataLedgerModel(
        store: MeetingStore,
        usesTemporaryStore: Bool,
        voiceGallery: VoiceGallery,
        voiceprintStore: VoiceprintStore
    ) -> LocalDataLedgerModel {
        LocalDataLedgerModel(
            client: AppLocalDataLedgerModelClient(useCase: LoadLocalDataLedger(
                meetings: AppLocalMeetingCounter(store: store),
                audio: AppLocalAudioUsageMeter(),
                voices: AppLocalVoiceCounter(
                    usesTemporaryStore: usesTemporaryStore,
                    voiceGallery: voiceGallery,
                    voiceprintStore: voiceprintStore))))
    }

    private static func makeModelStore(usesTemporaryStore: Bool) -> ModelStore {
        guard usesTemporaryStore else { return ModelStore() }
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "portavoz-uitest-models-\(UUID().uuidString)",
            isDirectory: true)
        return ModelStore(rootDirectory: rootDirectory)
    }

    private static func makeModelServices(
        usesTemporaryStore: Bool
    ) -> (ModelStore, VerifiedModelLifecycle) {
        let store = makeModelStore(usesTemporaryStore: usesTemporaryStore)
        return (store, VerifiedModelLifecycle(store: store))
    }

    private static func makeSensitiveStorage(
        usesTemporaryStore: Bool
    ) -> (
        secrets: any SecretStoring,
        voiceprintStore: VoiceprintStore,
        voiceGallery: VoiceGallery
    ) {
        let secrets: any SecretStoring
        let directory: URL
        if usesTemporaryStore {
            secrets = VolatileSecretStore()
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "portavoz-automation-sensitive-\(UUID().uuidString)",
                isDirectory: true)
        } else {
            secrets = KeychainSecretStore()
            directory = VoiceprintStore.defaultDirectory
        }
        return (
            secrets,
            VoiceprintStore(secrets: secrets, directory: directory),
            VoiceGallery(secrets: secrets, directory: directory))
    }

    private static func makeMeetingStore(
        storagePolicy: AppStorageIsolationPolicy
    ) throws -> MeetingStore {
        if storagePolicy.simulatesDatabaseOpenFailure {
            // XCUITest-only: materialize a valid disposable source so the
            // recovery-copy journey exercises SQLite read-only backup, then
            // fail before any production service is composed.
            _ = try MeetingStore(databaseURL: storagePolicy.meetingStoreURL)
            throw AppSimulatedDatabaseOpenFailure()
        }
        return try MeetingStore(databaseURL: storagePolicy.meetingStoreURL)
    }

    /// Searchable mutations wake both local search projections. Each process
    /// owner coalesces bursts; semantic maintenance remains storage-resumable
    /// and does not poll while no signal is pending.
    func requestSearchReconciliation() {
        let indexer = spotlightIndexer
        Task { await indexer.requestReindex() }
        guard resourceCaptureState.current == .inactive else {
            backgroundWork.markWaitingForRecording(.semanticIndex)
            backgroundWork.markWaitingForRecording(.memoryGraph)
            return
        }
        semanticIndexingSupervisor.kick()
        requestMemoryGraphReconciliation()
    }

    /// Topology-only mutations wake no text index. Durable graph triggers keep
    /// the cursor safe during capture; capture-stop reconciliation runs it.
    func requestMemoryGraphReconciliation() {
        guard resourceCaptureState.current == .inactive else {
            backgroundWork.markWaitingForRecording(.memoryGraph)
            return
        }
        memoryGraphProjectionSupervisor.kick()
    }

    /// Explicit readiness for workflows that truly need both models.
    func loadEnginesIfNeeded() async throws {
        let liveSpeech = try await acquireLiveSpeechRuntime()
        defer { _ = finishLiveSpeechRuntime(liveSpeech) }
        let diarization = try await acquireDiarizationRuntime()
        defer { _ = finishDiarizationRuntime(diarization) }
        modelsState = .ready
    }

    /// Drops idle speech-model weights. In-flight preparation owns its result
    /// until the workflow schedules a later release.
    func releaseRecordingEngines() {
        _ = releaseLiveSpeechRuntime()
        _ = releaseDiarizationRuntime()
        modelsState = .unknown
    }

    /// Keeps speech models hot for back-to-back work, then frees their memory.
    func scheduleRecordingEnginesRelease() {
        enginesIdleGeneration += 1
        let generation = enginesIdleGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard let self, generation == self.enginesIdleGeneration else { return }
            guard !self.refines.isRunning else { return }
            self.releaseRecordingEngines()
        }
    }

    func settleModelsState() {
        if transcriber != nil, diarizationRuntime != nil {
            modelsState = .ready
        } else if liveSpeechRuntimeLoad == nil, diarizationRuntimeLoad == nil {
            modelsState = .unknown
        }
    }

    // MARK: - Summary engine (D25/M12)

    var summaryEngine: SummaryEngine {
        if let stored = UserDefaults.standard.string(forKey: "summaryEngine"),
            let engine = SummaryEngine(rawValue: stored) {
            return engine
        }
        return foundationModelsCapability.defaultSummaryEngine
    }

    /// The Ollama model chosen in Settings, or nil if none is configured.
    var ollamaModel: String? {
        let model = (UserDefaults.standard.string(forKey: "ollamaModel") ?? "")
            .trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? nil : model
    }

    var foundationModelsCapability: FoundationModelsCapability {
        .current()
    }

    /// Whether the Apple on-device summary engine can run here. Used to only
    /// offer it as a per-meeting override when it would actually work.
    var appleSummaryAvailable: Bool {
        foundationModelsCapability.isAvailable
    }

    /// Live Companion currently requires the same Apple classifier. BYOK can
    /// answer a classified knowledge question but cannot replace that gate.
    var companionAvailable: Bool {
        foundationModelsCapability.isAvailable
    }

    // MARK: - Embedded MLX model (D25 last mile)

    @discardableResult
    func refreshMLXReadiness(forceVerification: Bool = false) async -> Bool {
        let installation = await modelLifecycle.installation(
            for: ModelCatalog.mlxQwen35,
            forceVerification: forceVerification)
        guard !Task.isCancelled else { return mlxDownloaded }
        mlxDownloaded = installation != nil
        return mlxDownloaded
    }

    /// Verified download (D7) with progress, same UX as the Whisper variants.
    func downloadMLX(progress: @escaping @MainActor (String) -> Void) async throws {
        _ = try await modelLifecycle.install(ModelCatalog.mlxQwen35) { update in
            guard update.totalBytes > 0 else { return }
            let percent = Int(update.fraction * 100)
            Task { @MainActor in
                progress(L10n.format("Downloading embedded model (2.3 GB, one time only)… %d%%", percent))
            }
        }
        mlxDownloaded = true
    }

    func deleteMLXModel() async throws {
        guard mlxRuntimeLoad == nil else {
            throw MLXRuntimeError.modelInUse
        }
        if mlxRuntimeDirectoryKey != nil,
           !(await releaseMLXRuntime()) {
            throw MLXRuntimeError.modelInUse
        }
        try await modelLifecycle.remove(ModelCatalog.mlxQwen35)
        mlxDownloaded = false
    }

}
