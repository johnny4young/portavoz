import ApplicationKit
import DiarizationKit
import Foundation
import IntegrationsKit
import IntelligenceKit
import ModelStoreKit
import Observation
import PortavozCore
import StorageKit
import SwiftUI
import TranscriptionKit

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
    /// One Ask application workflow feeds every macOS Ask presentation model.
    @ObservationIgnored let askClient: AppAskModelClient
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
    private(set) var transcriber: ParakeetEngine?
    private(set) var diarizer: PyannoteDiarizer?
    @ObservationIgnored var transcriberLoadTask: Task<ParakeetEngine, Error>?
    @ObservationIgnored var diarizerLoadTask: Task<PyannoteDiarizer, Error>?
    var enginesIdleGeneration = 0
    var whisper: WhisperEngine?
    var whisperVariantID: String?
    var whisperDownloadState: WhisperDownloadState = .idle
    @ObservationIgnored var whisperPreparedModel: WhisperEngine.PreparedModel?
    @ObservationIgnored var whisperPreparation: WhisperPreparation?
    @ObservationIgnored var whisperBackgroundPreparation: Task<Void, Never>?
    @ObservationIgnored var whisperProgressObservers: [UUID: WhisperProgressObserver] = [:]
    var whisperIdleGeneration = 0

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
    let transcriptionScheduler = TranscriptionScheduler()
    /// Process-scoped ownership of the durable post-capture worker and its
    /// single scheduled retry wake. The supervisor deduplicates launch and
    /// producer kicks without polling SQLite.
    let postCaptureProcessing = PostCaptureProcessingSupervisor()
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
    /// One-shot seek consumed by the detail view when a palette citation
    /// navigates to a meeting — jump to the cited moment.
    var pendingSeek: TimeInterval?
    /// The meeting that just finished recording — the detail view shows the
    /// post-meeting mirror (6a-2) once for it, if the setting is on and it
    /// qualifies. One-shot: consumed on show.
    var justRecorded: MeetingID?

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

    init() {
        let usesTemporaryStore = ProcessInfo.processInfo.arguments.contains("-use-temp-store")
        do {
            if usesTemporaryStore {
                // UI testing (`make test-ui`): a throwaway DB so a test run
                // never touches the real library.
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("portavoz-uitest-\(UUID().uuidString).sqlite")
                store = try MeetingStore(databaseURL: url)
            } else {
                store = try MeetingStore(databaseURL: MeetingStore.defaultDatabaseURL)
            }
        } catch {
            // No database, no app — surfacing a broken half-UI would be
            // worse than failing loudly at launch.
            fatalError("cannot open the Portavoz database: \(error)")
        }
        let askUseCase = Self.makeAskUseCase(
            store: store,
            usesTemporaryStore: usesTemporaryStore)
        askClient = AppAskModelClient(useCase: askUseCase)
        palette = CommandPaletteController(
            model: CommandPaletteModel(client: askClient))
        meetingSync = Self.makeMeetingSyncModel(
            store: store,
            usesTemporaryStore: usesTemporaryStore)
        libraryMarkdownBackup = LibraryMarkdownBackupModel(
            client: AppLibraryMarkdownBackupClient(store: store))
        spotlightIndexer = SpotlightIndexer(
            store: store,
            enabled: !usesTemporaryStore && SpotlightIndexer.indexingAvailable)
        requestSpotlightReindex()
    }

    /// Searchable mutations request eventual reconciliation. The actor owns
    /// burst coalescing, retries, and crash-resumable client state.
    func requestSpotlightReindex() {
        let indexer = spotlightIndexer
        Task { await indexer.requestReindex() }
    }

    /// Loads only the live/batch first-pass transcriber. Offline quality
    /// passes must not acquire this capability as a side effect.
    func loadTranscriberIfNeeded() async throws -> ParakeetEngine {
        enginesIdleGeneration += 1
        if let transcriber { return transcriber }
        if let transcriberLoadTask {
            let engine = try await transcriberLoadTask.value
            transcriber = engine
            return engine
        }

        modelsState = .downloading(L10n.text("Preparing models…"))
        let task = Task { @MainActor in
            try await ParakeetEngine.loadRecommended(store: ModelStore()) { progress in
                let percent = Int(progress.fraction * 100)
                Task { @MainActor [weak self] in
                    self?.modelsState = .downloading(
                        L10n.format("Downloading transcription model… %d%%", percent))
                }
            }
        }
        transcriberLoadTask = task
        do {
            let engine = try await task.value
            transcriber = engine
            transcriberLoadTask = nil
            settleModelsState()
            return engine
        } catch {
            transcriberLoadTask = nil
            modelsState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Loads only speaker diarization. Refine/Import and durable diarization
    /// share this task without requiring or duplicating Parakeet.
    func loadDiarizerIfNeeded() async throws -> PyannoteDiarizer {
        enginesIdleGeneration += 1
        if let diarizer { return diarizer }
        if let diarizerLoadTask {
            let engine = try await diarizerLoadTask.value
            diarizer = engine
            return engine
        }

        modelsState = .downloading(L10n.text("Preparing models…"))
        let voiceprint = try? VoiceprintStore().load()
        let task = Task { @MainActor in
            try await PyannoteDiarizer.loadRecommended(
                store: ModelStore(), voiceprint: voiceprint
            ) { progress in
                let percent = Int(progress.fraction * 100)
                Task { @MainActor [weak self] in
                    self?.modelsState = .downloading(
                        L10n.format("Downloading diarization model… %d%%", percent))
                }
            }
        }
        diarizerLoadTask = task
        do {
            let engine = try await task.value
            diarizer = engine
            diarizerLoadTask = nil
            settleModelsState()
            return engine
        } catch {
            diarizerLoadTask = nil
            modelsState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Explicit readiness for workflows that truly need both models.
    func loadEnginesIfNeeded() async throws {
        _ = try await loadTranscriberIfNeeded()
        _ = try await loadDiarizerIfNeeded()
        modelsState = .ready
    }

    /// Starts verified preparation without delaying audio capture. Per-model
    /// tasks deduplicate concurrent recording, recovery, and offline callers.
    func prepareRecordingEnginesInBackground() {
        guard transcriber == nil || diarizer == nil else {
            modelsState = .ready
            return
        }
        Task { @MainActor [weak self] in
            try? await self?.loadEnginesIfNeeded()
        }
    }

    /// Rebuilds diarization with the new identity state on its next use.
    func invalidateDiarizer() {
        diarizer = nil
    }

    /// Drops idle speech-model weights. In-flight preparation owns its result
    /// until the workflow schedules a later release.
    func releaseRecordingEngines() {
        guard transcriberLoadTask == nil, diarizerLoadTask == nil else { return }
        transcriber = nil
        diarizer = nil
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

    private func settleModelsState() {
        if transcriber != nil, diarizer != nil {
            modelsState = .ready
        } else if transcriberLoadTask == nil, diarizerLoadTask == nil {
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

    static func modelDir(_ descriptor: ModelDescriptor) -> URL {
        ModelStore.defaultRootDirectory.appendingPathComponent(
            descriptor.folderName, isDirectory: true)
    }

    var mlxDownloaded: Bool {
        FileManager.default.fileExists(
            atPath: Self.modelDir(ModelCatalog.mlxQwen35)
                .appendingPathComponent("model.safetensors").path)
    }

    /// Verified download (D7) with progress, same UX as the Whisper variants.
    func downloadMLX(progress: @escaping @MainActor (String) -> Void) async throws {
        _ = try await ModelStore().ensureAvailable(ModelCatalog.mlxQwen35) { update in
            guard update.totalBytes > 0 else { return }
            let percent = Int(update.fraction * 100)
            Task { @MainActor in
                progress(L10n.format("Downloading embedded model (2.3 GB, one time only)… %d%%", percent))
            }
        }
    }

    func deleteMLXModel() {
        try? FileManager.default.removeItem(at: Self.modelDir(ModelCatalog.mlxQwen35))
    }

}
