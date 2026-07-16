import DiarizationKit
import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit
import TranscriptionKit

/// Copied audio owned temporarily by the import workflow.
public struct ImportedMeetingAudio: Equatable, Sendable {
    public let fileURL: URL
    public let relativeDirectory: String

    public init(fileURL: URL, relativeDirectory: String) {
        self.fileURL = fileURL
        self.relativeDirectory = relativeDirectory
    }
}

/// Filesystem capability for copying and rolling back imported audio.
public protocol ImportMeetingAudioFiles: Sendable {
    func copySystemAudio(from source: URL, meetingID: MeetingID) async throws
        -> ImportedMeetingAudio
    func discardImportedAudio(_ audio: ImportedMeetingAudio) async throws
}

/// Platform-backed preferences sampled once at the import boundary.
public struct ImportMeetingPreferencesSnapshot: Sendable {
    public let transcriptLanguage: TranscriptLanguagePolicy
    public let summaryLanguage: SummaryLanguagePolicy
    public let summaryFallbackLanguage: LanguageCode
    public let vocabulary: [String]

    public init(
        transcriptLanguage: TranscriptLanguagePolicy,
        summaryLanguage: SummaryLanguagePolicy,
        summaryFallbackLanguage: LanguageCode,
        vocabulary: [String]
    ) {
        self.transcriptLanguage = transcriptLanguage
        self.summaryLanguage = summaryLanguage
        self.summaryFallbackLanguage = summaryFallbackLanguage
        self.vocabulary = vocabulary
    }
}

public protocol ImportMeetingPreferences: Sendable {
    func importMeetingPreferences() async -> ImportMeetingPreferencesSnapshot
}

/// Stable phases that presentation maps to localized copy.
public enum ImportMeetingProgress: Equatable, Sendable {
    case preparingModels
    case downloadingWhisper(size: String, percent: Int)
    case transcribing
    case identifyingSpeakers
    case generatingSummary
}

public typealias ImportMeetingProgressHandler =
    @Sendable (ImportMeetingProgress) async -> Void

/// Model capability used by audio import without exposing shared engine state.
public protocol ImportMeetingProcessor: Sendable {
    func prepareTranscriber(progress: @escaping ImportMeetingProgressHandler) async throws
    func prepareDiarizer() async throws
    func transcribe(
        audio: ImportedMeetingAudio,
        meetingID: MeetingID,
        languageHint: String?,
        vocabulary: [String]
    ) async throws -> FileTranscription
    func diarize(audio: ImportedMeetingAudio) async throws -> [SpeakerTurn]
    func scheduleIdleRelease() async
}

/// One concrete summary capability selected for the best-effort import path.
/// Provider construction and availability policy remain outside ApplicationKit.
public protocol ImportMeetingSummaryProvider: Sendable {
    var providerID: String { get }
    var modelID: String { get }
    var modelRevision: String? { get }

    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft
}

public enum ImportMeetingSummaryProviderResolution: Sendable {
    case available(any ImportMeetingSummaryProvider)
    case unavailable
}

public protocol ImportMeetingSummaryProviderResolver: Sendable {
    func resolveImportMeetingSummaryProvider() async
        -> ImportMeetingSummaryProviderResolution
}

/// Persistence boundary: the required aggregate is atomic; summary is optional.
public protocol ImportMeetingStore: Sendable {
    func installImportedMeeting(
        _ meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) async throws
    func saveImportedSummary(
        _ draft: SummaryDraft,
        generationRun: GenerationRun
    ) async throws
    func saveImportedSummaryRun(_ run: GenerationRun) async throws
}

extension MeetingStore: ImportMeetingStore {
    public func installImportedMeeting(
        _ meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) async throws {
        try await saveImportedMeeting(meeting, speakers: speakers, segments: segments)
    }

    public func saveImportedSummary(
        _ draft: SummaryDraft,
        generationRun: GenerationRun
    ) async throws {
        _ = try await saveSummary(draft, generationRun: generationRun)
    }

    public func saveImportedSummaryRun(_ run: GenerationRun) async throws {
        try await saveGenerationRun(run)
    }
}

public struct ImportMeetingRequest: Sendable {
    public let sourceURL: URL
    public let title: String
    public let progress: ImportMeetingProgressHandler

    public init(
        sourceURL: URL,
        title: String,
        progress: @escaping ImportMeetingProgressHandler = { _ in }
    ) {
        self.sourceURL = sourceURL
        self.title = title
        self.progress = progress
    }
}

/// Imports one external recording while preserving the released synchronous
/// UX, language policies, best-effort derivation, and idle-release behavior.
/// Copied audio is staged until the meeting, cast, and transcript commit.
public struct ImportMeeting: ApplicationUseCase {
    private let audioFiles: any ImportMeetingAudioFiles
    private let preferences: any ImportMeetingPreferences
    private let processor: any ImportMeetingProcessor
    private let store: any ImportMeetingStore
    private let summaryProviders: any ImportMeetingSummaryProviderResolver
    private let makeMeetingID: @Sendable () -> MeetingID
    private let makeGenerationRunID: @Sendable () -> GenerationRunID
    private let now: @Sendable () -> Date

    public init(
        audioFiles: any ImportMeetingAudioFiles,
        preferences: any ImportMeetingPreferences,
        processor: any ImportMeetingProcessor,
        store: any ImportMeetingStore,
        summaryProviders: any ImportMeetingSummaryProviderResolver,
        makeMeetingID: @escaping @Sendable () -> MeetingID = { MeetingID() },
        makeGenerationRunID: @escaping @Sendable () -> GenerationRunID = {
            GenerationRunID()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.audioFiles = audioFiles
        self.preferences = preferences
        self.processor = processor
        self.store = store
        self.summaryProviders = summaryProviders
        self.makeMeetingID = makeMeetingID
        self.makeGenerationRunID = makeGenerationRunID
        self.now = now
    }

    public func execute(_ request: ImportMeetingRequest) async throws -> MeetingID {
        let meetingID = makeMeetingID()
        let sampledPreferences = await preferences.importMeetingPreferences()
        let audio = try await audioFiles.copySystemAudio(
            from: request.sourceURL,
            meetingID: meetingID)
        var aggregateCommitted = false

        do {
            await request.progress(.preparingModels)
            try await processor.prepareTranscriber(progress: request.progress)
            do {
                try await processor.prepareDiarizer()
                let content = try await importedContent(
                    meetingID: meetingID,
                    audio: audio,
                    preferences: sampledPreferences,
                    progress: request.progress)
                let startedAt = now()
                let meeting = Meeting(
                    id: meetingID,
                    title: request.title,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(content.audioDuration),
                    language: content.spokenLanguage,
                    audioDirectory: audio.relativeDirectory)
                try await store.installImportedMeeting(
                    meeting,
                    speakers: content.speakers,
                    segments: content.segments)
                aggregateCommitted = true
                await saveSummaryIfPossible(
                    meetingID: meetingID,
                    content: content,
                    preferences: sampledPreferences,
                    progress: request.progress)
                await processor.scheduleIdleRelease()
                return meetingID
            } catch {
                await processor.scheduleIdleRelease()
                throw error
            }
        } catch {
            if !aggregateCommitted {
                try? await audioFiles.discardImportedAudio(audio)
            }
            throw error
        }
    }

    private func importedContent(
        meetingID: MeetingID,
        audio: ImportedMeetingAudio,
        preferences: ImportMeetingPreferencesSnapshot,
        progress: ImportMeetingProgressHandler
    ) async throws -> ImportedMeetingContent {
        await progress(.transcribing)
        let transcription = try await processor.transcribe(
            audio: audio,
            meetingID: meetingID,
            languageHint: preferences.transcriptLanguage.languageHint,
            vocabulary: preferences.vocabulary)
        await progress(.identifyingSpeakers)
        _ = try? await processor.prepareDiarizer()
        let turns = (try? await processor.diarize(audio: audio)) ?? []
        let attribution = SpeakerAttributor.attribute(
            segments: transcription.segments.sorted { $0.startTime < $1.startTime },
            turns: turns,
            meetingID: meetingID)
        return ImportedMeetingContent(
            audioDuration: transcription.audioDuration,
            segments: attribution.segments,
            speakers: attribution.speakers,
            spokenLanguage: SpokenLanguageDetector.homogeneousLanguage(
                in: attribution.segments))
    }

    private func saveSummaryIfPossible(
        meetingID: MeetingID,
        content: ImportedMeetingContent,
        preferences: ImportMeetingPreferencesSnapshot,
        progress: ImportMeetingProgressHandler
    ) async {
        await progress(.generatingSummary)
        let language = preferences.summaryLanguage.resolve(
            spokenLanguage: content.spokenLanguage,
            fallbackLanguage: preferences.summaryFallbackLanguage.identifier)
        let request = SummaryRequest(
            meetingID: meetingID,
            segments: content.segments,
            speakers: content.speakers,
            recipe: .general,
            targetLanguage: language.identifier,
            glossary: preferences.vocabulary)
        guard case .available(let provider) =
            await summaryProviders.resolveImportMeetingSummaryProvider()
        else { return }

        let attempt = ImportedSummaryGenerationAttempt(
            id: makeGenerationRunID(),
            request: request,
            provider: provider,
            inputFingerprint: SummaryFingerprint.compute(
                request: request,
                providerID: provider.providerID),
            startedAt: now())
        var generatedDraft: SummaryDraft?
        do {
            let draft = try await provider.summarize(request)
            generatedDraft = draft
            try await store.saveImportedSummary(
                draft,
                generationRun: attempt.finish(
                    outcome: .succeeded,
                    draft: draft,
                    at: now()))
        } catch {
            let outcome: GenerationRunOutcome = error is CancellationError
                ? .cancelled
                : .failed
            // Provenance remains best effort so summary diagnostics cannot
            // change the released best-effort import result.
            try? await store.saveImportedSummaryRun(
                attempt.finish(
                    outcome: outcome,
                    draft: generatedDraft,
                    at: now()))
        }
    }
}

private struct ImportedMeetingContent: Sendable {
    let audioDuration: TimeInterval
    let segments: [TranscriptSegment]
    let speakers: [Speaker]
    let spokenLanguage: String?
}

private struct ImportedSummaryGenerationAttempt: Sendable {
    let id: GenerationRunID
    let meetingID: MeetingID
    let providerID: String
    let modelID: String
    let modelRevision: String?
    let inputFingerprint: String
    let recipeID: String
    let outputLanguage: String
    let startedAt: Date

    init(
        id: GenerationRunID,
        request: SummaryRequest,
        provider: any ImportMeetingSummaryProvider,
        inputFingerprint: String,
        startedAt: Date
    ) {
        self.id = id
        meetingID = request.meetingID
        providerID = provider.providerID
        modelID = provider.modelID
        modelRevision = provider.modelRevision
        self.inputFingerprint = inputFingerprint
        recipeID = request.recipe.id
        outputLanguage = request.targetLanguage
        self.startedAt = startedAt
    }

    func finish(
        outcome: GenerationRunOutcome,
        draft: SummaryDraft?,
        at finishedAt: Date
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
                operation: "generate",
                recipeID: recipeID,
                workflow: "audio-import")),
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
        let operation: String
        let recipeID: String
        let workflow: String
    }

    private struct Metrics: Encodable {
        let actionItemCount: Int
        let outputUTF8Bytes: Int
    }
}
