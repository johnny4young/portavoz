import ApplicationKit
import CryptoKit
import DiarizationKit
import Foundation
import IntegrationsKit
import IntelligenceKit
import ModelStoreKit
import PortavozCore
import StorageKit
import TranscriptionKit

/// Egress ledger for standalone terminal work that has no library meeting to
/// own a durable receipt: the content-free attempt is announced on the
/// terminal BEFORE transport, mirroring the persisted receipt's fields. It
/// never prints meeting content, URLs beyond the host, or credentials.
struct TerminalDataEgressReceiptRecorder: DataEgressEventRecorder {
    func recordDataEgressEvent(_ event: DataEgressEvent) async throws {
        let model = event.modelID.map { " model \($0)" } ?? ""
        print(
            "egress: \(event.operation.rawValue) → \(event.destinationHost) "
                + "(\(event.dataClassification.rawValue), consent \(event.consentSource.rawValue),"
                + "\(model) provider \(event.providerID))")
    }
}

struct CLIFileAdapter: ApplicationInputFileAccess, ApplicationOutputFileWriting {
    func isReadableFile(_ url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory) && !isDirectory.boolValue
        }.value
    }

    func write(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try data.write(to: url)
        }.value
    }
}

/// Serializes synchronous model-download callbacks onto one async progress
/// handler and lets the owning workflow drain them before returning.
private final class CLIOrderedProgressRelay<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (Event) async -> Void
    private var tail: Task<Void, Never>?

    init(handler: @escaping @Sendable (Event) async -> Void) {
        self.handler = handler
    }

    func send(_ event: Event) {
        lock.lock()
        let previous = tail
        let handler = handler
        tail = Task {
            await previous?.value
            await handler(event)
        }
        lock.unlock()
    }

    func finish() async {
        await pendingTask()?.value
    }

    private func pendingTask() -> Task<Void, Never>? {
        lock.lock()
        let pending = tail
        lock.unlock()
        return pending
    }
}

private enum CLIModelLoader {
    static func parakeet(
        store: ModelStore,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> ParakeetEngine {
        let descriptor = ModelCatalog.parakeetTdtV3
        let report = await store.verify(descriptor)
        if !report.isComplete {
            await progress(.downloadingModel(
                name: descriptor.displayName,
                megabytes: descriptor.totalSizeBytes / 1_000_000))
        }
        let relay = CLIOrderedProgressRelay(handler: progress)
        let directory: URL
        do {
            directory = try await store.ensureAvailable(descriptor) { download in
                guard download.totalBytes > 0 else { return }
                relay.send(.downloadProgress(
                    percent: Int(download.fraction * 100),
                    path: download.currentPath))
            }
        } catch {
            await relay.finish()
            throw error
        }
        await relay.finish()
        await progress(.loadingTranscriptionModel)
        return try await ParakeetEngine.load(fromVerifiedDirectory: directory)
    }

    static func whisper(
        store: ModelStore,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> WhisperEngine {
        let descriptor = ModelCatalog.whisperLargeV3Turbo
        let report = await store.verify(descriptor)
        if !report.isComplete {
            await progress(.downloadingModel(
                name: descriptor.displayName,
                megabytes: descriptor.totalSizeBytes / 1_000_000))
        }
        let relay = CLIOrderedProgressRelay(handler: progress)
        do {
            let engine = try await WhisperEngine.loadRecommended(store: store) { download in
                guard download.totalBytes > 0 else { return }
                relay.send(.downloadProgress(
                    percent: Int(download.fraction * 100),
                    path: download.currentPath))
            }
            await relay.finish()
            return engine
        } catch {
            await relay.finish()
            throw error
        }
    }

    static func diarizer(
        store: ModelStore,
        threshold: Float,
        voiceprint: Voiceprint?,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> PyannoteDiarizer {
        let descriptor = ModelCatalog.speakerDiarization
        let report = await store.verify(descriptor)
        if !report.isComplete {
            await progress(.downloadingModel(
                name: descriptor.displayName,
                megabytes: descriptor.totalSizeBytes / 1_000_000))
        }
        return try await PyannoteDiarizer.loadRecommended(
            store: store,
            clusteringThreshold: threshold,
            voiceprint: voiceprint)
    }
}

struct CLIAudioTranscriptionProcessor: AudioFileTranscriptionProcessor {
    let modelsDirectory: String?

    func transcribe(
        fileURL: URL,
        engine: AudioAnalysisEngine,
        hints: TranscriptionHints,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> FileTranscription {
        let store = CLISupport.modelStore(fromModelsDir: modelsDirectory)
        switch engine {
        case .parakeet:
            return try await CLIModelLoader.parakeet(
                store: store,
                progress: progress).transcribeFile(at: fileURL, hints: hints)
        case .whisper:
            return try await CLIModelLoader.whisper(
                store: store,
                progress: progress).transcribeFile(at: fileURL, hints: hints)
        }
    }
}

actor CLIAudioDiarizationProcessor: AudioFileDiarizationProcessor {
    let modelsDirectory: String?
    let voiceprintStore: VoiceprintStore
    private var diarizer: PyannoteDiarizer?

    init(modelsDirectory: String?, voiceprintStore: VoiceprintStore) {
        self.modelsDirectory = modelsDirectory
        self.voiceprintStore = voiceprintStore
    }

    func prepare(
        clusteringThreshold: Float,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws {
        let store = CLISupport.modelStore(fromModelsDir: modelsDirectory)
        diarizer = try await CLIModelLoader.diarizer(
            store: store,
            threshold: clusteringThreshold,
            voiceprint: try? voiceprintStore.load(),
            progress: progress)
    }

    func diarize(
        fileURL: URL,
        clusteringThreshold: Float,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> [SpeakerTurn] {
        _ = clusteringThreshold
        _ = progress
        guard let diarizer else { throw CLIProductAdapterError.processorNotPrepared }
        return try await diarizer.diarizeFile(at: fileURL)
    }

    func transcribeForAttribution(
        fileURL: URL,
        hints: TranscriptionHints,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> FileTranscription {
        let store = CLISupport.modelStore(fromModelsDir: modelsDirectory)
        let engine = try await CLIModelLoader.parakeet(store: store, progress: progress)
        return try await engine.transcribeFile(at: fileURL, hints: hints)
    }
}

actor CLIAudioSummaryProcessor: AudioFileSummaryProcessor {
    let modelsDirectory: String?
    let voiceprintStore: VoiceprintStore
    let provider: any SummaryProvider
    private var transcriber: ParakeetEngine?
    private var diarizer: PyannoteDiarizer?

    init(
        modelsDirectory: String?,
        voiceprintStore: VoiceprintStore,
        provider: any SummaryProvider
    ) {
        self.modelsDirectory = modelsDirectory
        self.voiceprintStore = voiceprintStore
        self.provider = provider
    }

    func prepare(progress: @escaping AudioAnalysisProgressHandler) async throws {
        let store = CLISupport.modelStore(fromModelsDir: modelsDirectory)
        transcriber = try await CLIModelLoader.parakeet(store: store, progress: progress)
        diarizer = try await CLIModelLoader.diarizer(
            store: store,
            threshold: PyannoteDiarizer.defaultClusteringThreshold,
            voiceprint: try? voiceprintStore.load(),
            progress: progress)
    }

    func transcribe(
        fileURL: URL,
        hints: TranscriptionHints,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> FileTranscription {
        _ = progress
        guard let transcriber else { throw CLIProductAdapterError.processorNotPrepared }
        return try await transcriber.transcribeFile(at: fileURL, hints: hints)
    }

    func diarize(
        fileURL: URL,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> [SpeakerTurn] {
        _ = progress
        guard let diarizer else { throw CLIProductAdapterError.processorNotPrepared }
        return try await diarizer.diarizeFile(at: fileURL)
    }

    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        try await provider.summarize(request)
    }
}

struct CLIMeetingDocumentRenderer: MeetingDocumentRendering {
    func markdown(from detail: MeetingLibraryDetail) async throws -> String {
        MeetingExporter.markdown(
            meeting: detail.meeting,
            speakers: detail.speakers,
            segments: detail.segments,
            summary: detail.summary,
            summaryVersion: detail.summaryVersion)
    }

    func pdf(fromMarkdown markdown: String) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try MeetingExporter.pdf(fromMarkdown: markdown)
        }.value
    }
}

actor CLIGistDocumentPublisher: MeetingDocumentPublishing {
    let secrets: ManageSecrets
    let gateway: any DataEgressGateway
    let isPublic: Bool
    private var publisher: GistPublisher?

    init(
        secrets: ManageSecrets,
        gateway: any DataEgressGateway,
        isPublic: Bool
    ) {
        self.secrets = secrets
        self.gateway = gateway
        self.isPublic = isPublic
    }

    func prepare() async throws {
        guard publisher == nil else { return }
        guard let token = await CLICredentialResolver.resolve(
            secrets: secrets,
            identifier: .gitHubToken,
            environmentVariable: "PORTAVOZ_GITHUB_TOKEN")
        else {
            throw CLIProductAdapterError.missingGitHubToken
        }
        publisher = GistPublisher(token: token, gateway: gateway)
    }

    func publish(
        meetingID: MeetingID,
        markdown: String,
        filename: String,
        description: String
    ) async throws -> URL {
        guard let publisher else { throw CLIProductAdapterError.publisherNotPrepared }
        return try await publisher.publish(
            meetingID: meetingID,
            markdown: markdown,
            filename: filename,
            description: description,
            isPublic: isPublic)
    }
}

actor CLIMeetingActionItemPublisher: MeetingActionItemPublishing {
    let destination: CLIIssueDestination
    let secrets: ManageSecrets
    let gateway: any DataEgressGateway
    private var publisher: Publisher?

    init(
        destination: CLIIssueDestination,
        secrets: ManageSecrets,
        gateway: any DataEgressGateway
    ) {
        self.destination = destination
        self.secrets = secrets
        self.gateway = gateway
    }

    func prepare() async throws {
        guard publisher == nil else { return }
        switch destination {
        case .github(let repository):
            guard let token = await CLICredentialResolver.resolve(
                secrets: secrets,
                identifier: .gitHubToken,
                environmentVariable: "PORTAVOZ_GITHUB_TOKEN")
            else { throw CLIProductAdapterError.missingGitHubTokenSpanish }
            publisher = .github(GitHubIssuesExporter(
                repository: repository,
                token: token,
                gateway: gateway))
        case .linear(let teamID):
            guard let token = await CLICredentialResolver.resolve(
                secrets: secrets,
                identifier: .linearToken,
                environmentVariable: "PORTAVOZ_LINEAR_TOKEN")
            else { throw CLIProductAdapterError.missingLinearTokenSpanish }
            publisher = .linear(LinearExporter(
                teamID: teamID,
                token: token,
                gateway: gateway))
        }
    }

    func publish(
        _ item: ActionItem,
        meetingID: MeetingID,
        meetingTitle: String,
        ownerName: String?
    ) async throws -> URL {
        guard let publisher else { throw CLIProductAdapterError.publisherNotPrepared }
        switch publisher {
        case .github(let publisher):
            return try await publisher.publish(
                item,
                meetingID: meetingID,
                meetingTitle: meetingTitle,
                ownerName: ownerName)
        case .linear(let publisher):
            return try await publisher.publish(
                item,
                meetingID: meetingID,
                meetingTitle: meetingTitle,
                ownerName: ownerName)
        }
    }

    private enum Publisher {
        case github(GitHubIssuesExporter)
        case linear(LinearExporter)
    }
}

private enum CLICredentialResolver {
    static func resolve(
        secrets: ManageSecrets,
        identifier: SecretIdentifier,
        environmentVariable: String
    ) async -> String? {
        if let stored = try? await secrets.value(for: identifier), !stored.isEmpty {
            return stored
        }
        guard let fallback = ProcessInfo.processInfo.environment[environmentVariable],
              !fallback.isEmpty
        else { return nil }
        return fallback
    }
}

struct CLILocalVoiceIdentityStore: LocalVoiceIdentityStoring {
    let store: VoiceprintStore

    func loadVoiceIdentity() async throws -> Voiceprint? {
        try await Task.detached(priority: .utility) { try store.load() }.value
    }

    func saveVoiceIdentity(_ voiceprint: Voiceprint) async throws {
        try await Task.detached(priority: .utility) { try store.save(voiceprint) }.value
    }

    func deleteVoiceIdentity() async throws {
        try await Task.detached(priority: .utility) { try store.delete() }.value
    }
}

struct CLILocalVoiceIdentityExtractor: LocalVoiceIdentityExtracting {
    let modelsDirectory: String?

    func extractVoiceIdentity(from fileURL: URL) async throws -> Voiceprint {
        let store = CLISupport.modelStore(fromModelsDir: modelsDirectory)
        let diarizer = try await PyannoteDiarizer.loadRecommended(store: store)
        return try await diarizer.extractVoiceprint(fromFile: fileURL)
    }
}

struct CLILocalModelLifecycleManager: LocalModelLifecycleManaging {
    let modelsDirectory: String?

    var catalog: [LocalModelDescriptor] {
        [ModelCatalog.parakeetTdtV3, ModelCatalog.speakerDiarization].map(Self.application)
    }

    func verification(for descriptor: LocalModelDescriptor) async -> LocalModelVerification {
        let store = CLISupport.modelStore(fromModelsDir: modelsDirectory)
        guard let concrete = concrete(descriptor) else {
            return LocalModelVerification(
                descriptor: descriptor,
                directory: await store.directory(for: ModelCatalog.parakeetTdtV3),
                missing: [descriptor.id],
                corrupted: [])
        }
        let report = await store.verify(concrete)
        return LocalModelVerification(
            descriptor: descriptor,
            directory: await store.directory(for: concrete),
            missing: report.missing,
            corrupted: report.corrupted)
    }

    func installAndProveLoadable(
        _ descriptor: LocalModelDescriptor,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws {
        let store = CLISupport.modelStore(fromModelsDir: modelsDirectory)
        guard let concrete = concrete(descriptor) else {
            throw CLIProductAdapterError.unknownModel(descriptor.id)
        }
        if concrete.tasks.contains(.liveTranscription) {
            _ = try await CLIModelLoader.parakeet(store: store, progress: progress)
        } else if concrete.tasks.contains(.diarization) {
            _ = try await CLIModelLoader.diarizer(
                store: store,
                threshold: PyannoteDiarizer.defaultClusteringThreshold,
                voiceprint: nil,
                progress: progress)
        } else {
            throw CLIProductAdapterError.unknownModel(descriptor.id)
        }
    }

    private func concrete(_ descriptor: LocalModelDescriptor) -> ModelDescriptor? {
        [ModelCatalog.parakeetTdtV3, ModelCatalog.speakerDiarization]
            .first { $0.id == descriptor.id }
    }

    private static func application(_ descriptor: ModelDescriptor) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: descriptor.id,
            displayName: descriptor.displayName,
            revision: descriptor.revision,
            totalSizeMegabytes: descriptor.totalSizeBytes / 1_000_000,
            artifactCount: descriptor.artifacts.count)
    }
}

struct CLIRefineAudioFiles: RefineMeetingAudioFiles {
    func resolveRefineAudio(
        _ relativeDirectory: String,
        meetingID: MeetingID
    ) async throws -> RefineMeetingAudio {
        _ = meetingID
        let base = RecordingsLocation.shared.resolve(relativeDirectory)
        return try await Task.detached(priority: .utility) {
            RefineMeetingAudio(
                system: try Self.channel(MeetingAudioLayout.channelFile(
                    named: "system",
                    in: base)),
                microphone: try Self.channel(MeetingAudioLayout.channelFile(
                    named: "microphone",
                    in: base)))
        }.value
    }

    func resolveExternalRefineAudio(
        _ fileURL: URL,
        meetingID: MeetingID
    ) async throws -> RefineMeetingAudio {
        _ = meetingID
        return try await Task.detached(priority: .utility) {
            RefineMeetingAudio(
                system: try Self.channel(fileURL),
                microphone: nil)
        }.value
    }

    static func channel(_ fileURL: URL?) throws -> RefineMeetingAudioChannel? {
        guard let fileURL else { return nil }
        return RefineMeetingAudioChannel(
            fileURL: fileURL,
            isSilent: false,
            contentFingerprint: try sha256(of: fileURL))
    }

    private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

actor CLIRefineMeetingProcessor: RefineMeetingProcessor {
    let modelsDirectory: String?
    let clusteringThreshold: Float
    let voiceprintStore: VoiceprintStore
    private var whisper: WhisperEngine?

    init(
        modelsDirectory: String?,
        clusteringThreshold: Float,
        voiceprintStore: VoiceprintStore
    ) {
        self.modelsDirectory = modelsDirectory
        self.clusteringThreshold = clusteringThreshold
        self.voiceprintStore = voiceprintStore
    }

    func transcriptionProvider() -> RefineMeetingTranscriptionProvider {
        let descriptor = ModelCatalog.whisperLargeV3Turbo
        return RefineMeetingTranscriptionProvider(
            providerID: "whisperkit/coreml",
            modelID: descriptor.id,
            modelRevision: descriptor.revision)
    }

    func prepare(progress: @escaping RefineMeetingProgressHandler) async throws {
        let store = CLISupport.modelStore(fromModelsDir: modelsDirectory)
        let descriptor = ModelCatalog.whisperLargeV3Turbo
        let report = await store.verify(descriptor)
        if !report.isComplete {
            await progress(.downloadingWhisper(
                size: "\(descriptor.totalSizeBytes / 1_000_000) MB",
                percent: 0))
            let relay = CLIOrderedProgressRelay<RefineMeetingProgress>(handler: progress)
            do {
                whisper = try await WhisperEngine.loadRecommended(store: store) { download in
                    guard download.totalBytes > 0 else { return }
                    relay.send(.downloadingWhisper(
                        size: "\(descriptor.totalSizeBytes / 1_000_000) MB",
                        percent: Int(download.fraction * 100),
                        path: download.currentPath))
                }
                await relay.finish()
            } catch {
                await relay.finish()
                throw error
            }
        } else {
            whisper = try await WhisperEngine.loadRecommended(store: store)
        }
    }

    func transcribe(
        fileURL: URL,
        hints: TranscriptionHints,
        channel: AudioChannel
    ) async throws -> FileTranscription {
        guard let whisper else { throw CLIProductAdapterError.processorNotPrepared }
        return try await whisper.transcribeFile(at: fileURL, hints: hints, channel: channel)
    }

    func diarize(fileURL: URL) async throws -> [SpeakerTurn] {
        let store = CLISupport.modelStore(fromModelsDir: modelsDirectory)
        let diarizer = try await PyannoteDiarizer.loadRecommended(
            store: store,
            clusteringThreshold: clusteringThreshold,
            voiceprint: try? voiceprintStore.load())
        return try await diarizer.diarizeFile(at: fileURL)
    }

    func scheduleIdleRelease() {}
}

struct CLIRefineMeetingPreferences: RefineMeetingPreferences {
    let snapshot: RefineMeetingPreferencesSnapshot

    func refineMeetingPreferences() -> RefineMeetingPreferencesSnapshot { snapshot }
}

struct CLIDisabledRefineCompanion: RefineMeetingCompanion {
    func isRefreshAvailable() -> Bool { false }

    func refresh(
        segments: [TranscriptSegment],
        meetingID: MeetingID,
        transcriptRevision: Int
    ) -> RefineMeetingCompanionRefresh {
        _ = segments
        _ = meetingID
        _ = transcriptRevision
        return RefineMeetingCompanionRefresh(cards: [], completed: false)
    }
}

enum CLIProductAdapterError: Error, LocalizedError {
    case processorNotPrepared
    case publisherNotPrepared
    case missingGitHubToken
    case missingGitHubTokenSpanish
    case missingLinearTokenSpanish
    case unknownModel(String)

    var errorDescription: String? {
        switch self {
        case .processorNotPrepared:
            "model processor was not prepared"
        case .publisherNotPrepared:
            "publisher was not prepared"
        case .missingGitHubToken:
            "no GitHub token — run `portavoz-cli secrets set-github-token <token>` "
                + "(or set PORTAVOZ_GITHUB_TOKEN)"
        case .missingGitHubTokenSpanish:
            "sin token de GitHub — `portavoz-cli secrets set-github-token <t>`"
        case .missingLinearTokenSpanish:
            "sin token de Linear — `portavoz-cli secrets set-linear-token <t>`"
        case .unknownModel(let id):
            "unknown model \(id)"
        }
    }
}
