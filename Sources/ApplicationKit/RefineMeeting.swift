import DiarizationKit
import Foundation
import PortavozCore
import StorageKit
import TranscriptionKit

/// One persisted channel considered by the quality re-pass.
public struct RefineMeetingAudioChannel: Equatable, Sendable {
    public let fileURL: URL
    public let isSilent: Bool
    /// Digest of the exact audio bytes; raw paths never enter provenance.
    public let contentFingerprint: String

    public init(fileURL: URL, isSilent: Bool, contentFingerprint: String) {
        self.fileURL = fileURL
        self.isSilent = isSilent
        self.contentFingerprint = contentFingerprint
    }
}

/// Audio resolved outside the application layer's platform-neutral workflow.
public struct RefineMeetingAudio: Equatable, Sendable {
    public let system: RefineMeetingAudioChannel?
    public let microphone: RefineMeetingAudioChannel?

    public init(
        system: RefineMeetingAudioChannel?,
        microphone: RefineMeetingAudioChannel?
    ) {
        self.system = system
        self.microphone = microphone
    }

    public var hasStoredChannel: Bool { system != nil || microphone != nil }
}

/// Filesystem and media inspection kept in the app adapter.
public protocol RefineMeetingAudioFiles: Sendable {
    func resolveRefineAudio(
        _ relativeDirectory: String,
        meetingID: MeetingID
    ) async throws -> RefineMeetingAudio
    func resolveExternalRefineAudio(
        _ fileURL: URL,
        meetingID: MeetingID
    ) async throws -> RefineMeetingAudio
}

public extension RefineMeetingAudioFiles {
    func resolveExternalRefineAudio(
        _ fileURL: URL,
        meetingID: MeetingID
    ) async throws -> RefineMeetingAudio {
        _ = fileURL
        _ = meetingID
        throw RefineMeetingError.audioUnavailable
    }
}

public struct RefineMeetingPreferencesSnapshot: Sendable {
    public let transcriptLanguage: TranscriptLanguagePolicy
    public let vocabulary: [String]

    public init(transcriptLanguage: TranscriptLanguagePolicy, vocabulary: [String]) {
        self.transcriptLanguage = transcriptLanguage
        self.vocabulary = vocabulary
    }
}

public protocol RefineMeetingPreferences: Sendable {
    func refineMeetingPreferences() async -> RefineMeetingPreferencesSnapshot
}

/// Stable phases that presentation maps to localized copy.
public enum RefineMeetingProgress: Equatable, Sendable {
    case preparingModels
    case downloadingWhisper(size: String, percent: Int, path: String? = nil)
    case transcribingParticipants
    case transcribingMicrophone
    case transcribed(
        channel: AudioChannel,
        audioDuration: TimeInterval,
        processingTime: TimeInterval,
        speedFactor: Double)
    case identifyingSpeakers
}

public typealias RefineMeetingProgressHandler =
    @Sendable (RefineMeetingProgress) async -> Void

/// Exact transcriber selected for one Refine use-case instance.
public struct RefineMeetingTranscriptionProvider: Equatable, Sendable {
    public let providerID: String
    public let modelID: String
    public let modelRevision: String?

    public init(providerID: String, modelID: String, modelRevision: String?) {
        self.providerID = providerID
        self.modelID = modelID
        self.modelRevision = modelRevision
    }
}

/// Concrete Whisper/diarizer ownership remains in the app composition root.
public protocol RefineMeetingProcessor: Sendable {
    func transcriptionProvider() async -> RefineMeetingTranscriptionProvider
    func prepare(progress: @escaping RefineMeetingProgressHandler) async throws
    func transcribe(
        fileURL: URL,
        hints: TranscriptionHints,
        channel: AudioChannel
    ) async throws -> FileTranscription
    func diarize(fileURL: URL) async throws -> [SpeakerTurn]
    func scheduleIdleRelease() async
}

public enum RefineMeetingError: Error, Equatable, LocalizedError, Sendable {
    case audioNotRetained
    case audioUnavailable

    public var errorDescription: String? {
        switch self {
        case .audioNotRetained, .audioUnavailable:
            "the meeting has no stored audio — use --file <wav>"
        }
    }
}

public struct RefineMeetingRequest: Sendable {
    public let detail: MeetingDetail
    public let languagePolicy: TranscriptLanguagePolicy?
    public let audioOverride: RefineMeetingAudio?
    public let progress: RefineMeetingProgressHandler

    public init(
        detail: MeetingDetail,
        languagePolicy: TranscriptLanguagePolicy? = nil,
        audioOverride: RefineMeetingAudio? = nil,
        progress: @escaping RefineMeetingProgressHandler = { _ in }
    ) {
        self.detail = detail
        self.languagePolicy = languagePolicy
        self.audioOverride = audioOverride
        self.progress = progress
    }
}

/// Produces a reviewable draft without mutating the current meeting.
/// Required model/transcription failures propagate; diarization remains
/// degradable, and every model-owning exit schedules the released idle policy.
public struct RefineMeeting: ApplicationUseCase {
    private let audioFiles: any RefineMeetingAudioFiles
    private let preferences: any RefineMeetingPreferences
    private let processor: any RefineMeetingProcessor
    private let store: any RefineMeetingStore
    private let makeGenerationRunID: @Sendable () -> GenerationRunID
    private let now: @Sendable () -> Date

    public init(
        audioFiles: any RefineMeetingAudioFiles,
        preferences: any RefineMeetingPreferences,
        processor: any RefineMeetingProcessor,
        store: any RefineMeetingStore,
        makeGenerationRunID: @escaping @Sendable () -> GenerationRunID = {
            GenerationRunID()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.audioFiles = audioFiles
        self.preferences = preferences
        self.processor = processor
        self.store = store
        self.makeGenerationRunID = makeGenerationRunID
        self.now = now
    }

    public func execute(_ request: RefineMeetingRequest) async throws -> RefineDraft {
        let audio: RefineMeetingAudio
        if let audioOverride = request.audioOverride {
            audio = audioOverride
        } else {
            guard let relativeDirectory = request.detail.meeting.audioDirectory else {
                throw RefineMeetingError.audioNotRetained
            }
            audio = try await audioFiles.resolveRefineAudio(
                relativeDirectory,
                meetingID: request.detail.meeting.id)
        }
        guard audio.hasStoredChannel else { throw RefineMeetingError.audioUnavailable }

        await request.progress(.preparingModels)
        do {
            let draft = try await buildDraft(request: request, audio: audio)
            await processor.scheduleIdleRelease()
            return draft
        } catch {
            await processor.scheduleIdleRelease()
            throw error
        }
    }

    private func buildDraft(
        request: RefineMeetingRequest,
        audio: RefineMeetingAudio
    ) async throws -> RefineDraft {
        try Task.checkCancellation()
        try await processor.prepare(progress: request.progress)
        try Task.checkCancellation()

        let preferences = await preferences.refineMeetingPreferences()
        let detail = request.detail
        let policy = request.languagePolicy ?? preferences.transcriptLanguage
        let hints = TranscriptionHints(
            language: SpokenLanguageDetector.transcriptionLanguageHint(
                for: detail.meeting,
                segments: detail.segments,
                policy: policy),
            vocabulary: preferences.vocabulary,
            meetingID: detail.meeting.id)
        let attempt = try await generationAttempt(
            detail: detail,
            audio: audio,
            hints: hints)
        do {
            let segments = try await transcribe(
                audio: audio,
                hints: hints,
                progress: request.progress)
            let turns = try await speakerTurns(audio: audio, progress: request.progress)
            let attribution = SpeakerAttributor.attribute(
                segments: segments,
                turns: turns,
                meetingID: detail.meeting.id)
            return refinedDraft(
                detail: detail,
                attribution: attribution,
                attempt: attempt)
        } catch {
            if let attempt {
                let outcome: GenerationRunOutcome = error is CancellationError
                    ? .cancelled
                    : .failed
                try? await store.saveRefineGenerationRun(
                    attempt.finish(
                        outcome: outcome,
                        outputLanguage: hints.language,
                        segments: nil,
                        at: now()))
            }
            throw error
        }
    }

    private func refinedDraft(
        detail: MeetingDetail,
        attribution: SpeakerAttributor.Attribution,
        attempt: RefinedTranscriptGenerationAttempt?
    ) -> RefineDraft {
        let language = SpokenLanguageDetector.homogeneousLanguage(
            in: attribution.segments)
        let oldSpeech = detail.segments.reduce(0) {
            $0 + ($1.endTime - $1.startTime)
        }
        let meetingSeconds = detail.meeting.endedAt.map {
            $0.timeIntervalSince(detail.meeting.startedAt)
        }
        return RefineDraft(
            sourceTranscriptRevision: detail.meeting.transcriptRevision,
            language: language,
            speakers: attribution.speakers,
            segments: attribution.segments,
            oldSegmentCount: detail.segments.count,
            oldSpeakerCount: detail.speakers.count,
            oldSpeechSeconds: oldSpeech,
            meetingSeconds: meetingSeconds,
            generationRun: attempt?.finish(
                outcome: .succeeded,
                outputLanguage: language,
                segments: attribution.segments,
                at: now()))
    }

    private func generationAttempt(
        detail: MeetingDetail,
        audio: RefineMeetingAudio,
        hints: TranscriptionHints
    ) async throws -> RefinedTranscriptGenerationAttempt? {
        let channels = [
            audio.system.map { ($0, AudioChannel.system) },
            audio.microphone.map { ($0, AudioChannel.microphone) }
        ].compactMap { value -> RefineTranscriptionChannelEvidence? in
            guard let (channel, kind) = value, !channel.isSilent else { return nil }
            return RefineTranscriptionChannelEvidence(
                channel: kind,
                contentFingerprint: channel.contentFingerprint)
        }
        guard !channels.isEmpty else { return nil }

        let provider = await processor.transcriptionProvider()
        guard let fingerprint = RefineTranscriptionOperationFingerprint.compute(.init(
            meetingID: detail.meeting.id,
            sourceTranscriptRevision: detail.meeting.transcriptRevision,
            providerID: provider.providerID,
            modelID: provider.modelID,
            modelRevision: provider.modelRevision,
            languageHint: hints.language,
            vocabulary: hints.vocabulary,
            channels: channels))
        else { throw RefineMeetingError.audioUnavailable }

        return RefinedTranscriptGenerationAttempt(
            id: makeGenerationRunID(),
            meetingID: detail.meeting.id,
            provider: provider,
            inputFingerprint: fingerprint,
            sourceTranscriptRevision: detail.meeting.transcriptRevision,
            channels: channels.map(\.channel),
            languageHint: hints.language,
            vocabularyCount: hints.vocabulary.count,
            startedAt: now())
    }

    private func transcribe(
        audio: RefineMeetingAudio,
        hints: TranscriptionHints,
        progress: RefineMeetingProgressHandler
    ) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        if let system = audio.system, !system.isSilent {
            await progress(.transcribingParticipants)
            let result = try await processor.transcribe(
                fileURL: system.fileURL,
                hints: hints,
                channel: .system)
            await progress(.transcribed(
                channel: .system,
                audioDuration: result.audioDuration,
                processingTime: result.processingTime,
                speedFactor: result.speedFactor))
            segments.append(contentsOf: result.segments)
            try Task.checkCancellation()
        }
        if let microphone = audio.microphone, !microphone.isSilent {
            await progress(.transcribingMicrophone)
            let result = try await processor.transcribe(
                fileURL: microphone.fileURL,
                hints: hints,
                channel: .microphone)
            await progress(.transcribed(
                channel: .microphone,
                audioDuration: result.audioDuration,
                processingTime: result.processingTime,
                speedFactor: result.speedFactor))
            let voiced = result.segments.filter {
                !TranscriptNoiseFilter.isLikelyNoise(
                    text: $0.text,
                    confidence: $0.confidence)
            }
            segments.append(contentsOf: MicBleedFilter.filter(
                microphone: voiced,
                system: segments))
            try Task.checkCancellation()
        }
        return segments.sorted { $0.startTime < $1.startTime }
    }

    private func speakerTurns(
        audio: RefineMeetingAudio,
        progress: RefineMeetingProgressHandler
    ) async throws -> [SpeakerTurn] {
        guard let system = audio.system, !system.isSilent else { return [] }
        await progress(.identifyingSpeakers)
        do {
            let turns = try await processor.diarize(fileURL: system.fileURL)
            try Task.checkCancellation()
            return turns
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }
}

/// Atomic persistence used when the user accepts a reviewed draft.
public protocol RefineMeetingStore: Sendable {
    func installRefinedCast(
        meetingID: MeetingID,
        expectedTranscriptRevision: Int,
        language: String?,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        generationRun: GenerationRun?
    ) async throws
    func saveRefineGenerationRun(_ run: GenerationRun) async throws
    func saveRefinedCompanionGenerationRun(
        _ run: GenerationRun,
        sourceTranscriptRevision: Int
    ) async throws
    func replaceRefinedCompanionCards(
        _ cards: [CompanionCard],
        generated artifacts: [CompanionGenerationArtifact],
        for meetingID: MeetingID
    ) async throws
}

extension MeetingStore: RefineMeetingStore {
    public func installRefinedCast(
        meetingID: MeetingID,
        expectedTranscriptRevision: Int,
        language: String?,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        generationRun: GenerationRun?
    ) async throws {
        try await applyRefinedCast(
            for: meetingID,
            expectedTranscriptRevision: expectedTranscriptRevision,
            language: language,
            speakers: speakers,
            segments: segments,
            generationRun: generationRun)
    }

    public func saveRefineGenerationRun(_ run: GenerationRun) async throws {
        try await saveGenerationRun(run)
    }

    public func saveRefinedCompanionGenerationRun(
        _ run: GenerationRun,
        sourceTranscriptRevision: Int
    ) async throws {
        try await saveCompanionGenerationRun(
            run,
            workflow: "post-refine",
            sourceTranscriptRevision: sourceTranscriptRevision)
    }

    public func replaceRefinedCompanionCards(
        _ cards: [CompanionCard],
        generated artifacts: [CompanionGenerationArtifact],
        for meetingID: MeetingID
    ) async throws {
        try await replaceCompanionCards(cards, generated: artifacts, for: meetingID)
    }
}

public struct RefineMeetingCompanionRefresh: Sendable {
    public let cards: [CompanionCard]
    public let artifacts: [CompanionGenerationArtifact]
    public let terminalRuns: [GenerationRun]
    public let completed: Bool

    public init(
        cards: [CompanionCard],
        artifacts: [CompanionGenerationArtifact] = [],
        terminalRuns: [GenerationRun] = [],
        completed: Bool
    ) {
        self.cards = cards
        self.artifacts = artifacts
        self.terminalRuns = terminalRuns
        self.completed = completed
    }
}

/// Companion model capability; platform/version/preference checks stay private
/// to the app adapter.
public protocol RefineMeetingCompanion: Sendable {
    func isRefreshAvailable() async -> Bool
    func refresh(
        segments: [TranscriptSegment],
        meetingID: MeetingID,
        transcriptRevision: Int
    ) async -> RefineMeetingCompanionRefresh
}

public enum ApplyRefinedMeetingProgress: Equatable, Sendable {
    case applyingTranscript
    case refreshingCompanion
}

public typealias ApplyRefinedMeetingProgressHandler =
    @Sendable (ApplyRefinedMeetingProgress) async -> Void

public enum ApplyRefinedMeetingError: Error, Equatable, Sendable {
    case emptyDraft
}

public enum RefinedCompanionOutcome: Equatable, Sendable {
    case skipped
    case preserved
    case replaced(count: Int)
    case persistenceFailed
}

public struct ApplyRefinedMeetingResult: Equatable, Sendable {
    public let transcriptRevision: Int
    public let companion: RefinedCompanionOutcome

    public init(transcriptRevision: Int, companion: RefinedCompanionOutcome) {
        self.transcriptRevision = transcriptRevision
        self.companion = companion
    }
}

public struct ApplyRefinedMeetingRequest: Sendable {
    public let meetingID: MeetingID
    public let draft: RefineDraft
    public let progress: ApplyRefinedMeetingProgressHandler

    public init(
        meetingID: MeetingID,
        draft: RefineDraft,
        progress: @escaping ApplyRefinedMeetingProgressHandler = { _ in }
    ) {
        self.meetingID = meetingID
        self.draft = draft
        self.progress = progress
    }
}

/// Accepts one reviewed draft. Language, revision, cast, and transcript commit
/// together; immutable summaries remain history. Companion refresh is optional
/// and can never turn an accepted transcript into a failed apply.
public struct ApplyRefinedMeeting: ApplicationUseCase {
    private let store: any RefineMeetingStore
    private let companion: any RefineMeetingCompanion

    public init(store: any RefineMeetingStore, companion: any RefineMeetingCompanion) {
        self.store = store
        self.companion = companion
    }

    public func execute(
        _ request: ApplyRefinedMeetingRequest
    ) async throws -> ApplyRefinedMeetingResult {
        guard !request.draft.segments.isEmpty else {
            throw ApplyRefinedMeetingError.emptyDraft
        }
        await request.progress(.applyingTranscript)
        try await store.installRefinedCast(
            meetingID: request.meetingID,
            expectedTranscriptRevision: request.draft.sourceTranscriptRevision,
            language: request.draft.language,
            speakers: request.draft.speakers,
            segments: request.draft.segments,
            generationRun: request.draft.generationRun)

        let outcome = await refreshCompanionIfAvailable(request)
        return ApplyRefinedMeetingResult(
            transcriptRevision: request.draft.sourceTranscriptRevision + 1,
            companion: outcome)
    }

    private func refreshCompanionIfAvailable(
        _ request: ApplyRefinedMeetingRequest
    ) async -> RefinedCompanionOutcome {
        guard await companion.isRefreshAvailable() else { return .skipped }
        await request.progress(.refreshingCompanion)
        let refreshed = await companion.refresh(
            segments: request.draft.segments,
            meetingID: request.meetingID,
            transcriptRevision: request.draft.sourceTranscriptRevision + 1)
        for run in refreshed.terminalRuns {
            try? await store.saveRefinedCompanionGenerationRun(
                run,
                sourceTranscriptRevision: request.draft.sourceTranscriptRevision + 1)
        }
        guard refreshed.completed else { return .preserved }
        do {
            try await store.replaceRefinedCompanionCards(
                refreshed.cards,
                generated: refreshed.artifacts,
                for: request.meetingID)
            return .replaced(count: refreshed.cards.count + refreshed.artifacts.count)
        } catch {
            return .persistenceFailed
        }
    }
}

public struct RefineMeetingUseCases: Sendable {
    public let draft: RefineMeeting
    public let apply: ApplyRefinedMeeting
    public let run: RefinePersistedMeeting

    public init(
        audioFiles: any RefineMeetingAudioFiles,
        preferences: any RefineMeetingPreferences,
        processor: any RefineMeetingProcessor,
        store: any RefineMeetingStore,
        reader: any PersistedMeetingRefineReading,
        companion: any RefineMeetingCompanion
    ) {
        draft = RefineMeeting(
            audioFiles: audioFiles,
            preferences: preferences,
            processor: processor,
            store: store)
        apply = ApplyRefinedMeeting(store: store, companion: companion)
        run = RefinePersistedMeeting(
            audioFiles: audioFiles,
            draft: draft,
            apply: apply,
            reader: reader)
    }
}

public protocol PersistedMeetingRefineReading: Sendable {
    func persistedMeetingDetail(_ meetingID: MeetingID) async throws -> MeetingDetail?
}

extension MeetingStore: PersistedMeetingRefineReading {
    public func persistedMeetingDetail(_ meetingID: MeetingID) async throws -> MeetingDetail? {
        try await detail(meetingID)
    }
}

public enum RefinePersistedMeetingError: Error, Equatable, LocalizedError, Sendable {
    case meetingNotFound

    public var errorDescription: String? { "no such meeting" }
}

public struct RefinePersistedMeetingRequest: Sendable {
    public let meetingID: MeetingID
    public let externalAudioURL: URL?
    public let languagePolicy: TranscriptLanguagePolicy?
    public let progress: RefineMeetingProgressHandler

    public init(
        meetingID: MeetingID,
        externalAudioURL: URL? = nil,
        languagePolicy: TranscriptLanguagePolicy? = nil,
        progress: @escaping RefineMeetingProgressHandler = { _ in }
    ) {
        self.meetingID = meetingID
        self.externalAudioURL = externalAudioURL
        self.languagePolicy = languagePolicy
        self.progress = progress
    }
}

public struct RefinePersistedMeetingResult: Sendable {
    public let segmentCount: Int
    public let speakerCount: Int
    public let transcriptRevision: Int

    public init(segmentCount: Int, speakerCount: Int, transcriptRevision: Int) {
        self.segmentCount = segmentCount
        self.speakerCount = speakerCount
        self.transcriptRevision = transcriptRevision
    }
}

/// Loads one persisted meeting, builds the final transcript draft, and applies
/// it atomically. Presentation clients provide identity and optional file input
/// without coordinating storage, model, attribution, or revision policy.
public struct RefinePersistedMeeting: ApplicationUseCase {
    private let audioFiles: any RefineMeetingAudioFiles
    private let draft: RefineMeeting
    private let apply: ApplyRefinedMeeting
    private let reader: any PersistedMeetingRefineReading

    public init(
        audioFiles: any RefineMeetingAudioFiles,
        draft: RefineMeeting,
        apply: ApplyRefinedMeeting,
        reader: any PersistedMeetingRefineReading
    ) {
        self.audioFiles = audioFiles
        self.draft = draft
        self.apply = apply
        self.reader = reader
    }

    public func execute(
        _ request: RefinePersistedMeetingRequest
    ) async throws -> RefinePersistedMeetingResult {
        guard let detail = try await reader.persistedMeetingDetail(request.meetingID) else {
            throw RefinePersistedMeetingError.meetingNotFound
        }
        let audioOverride: RefineMeetingAudio?
        if let externalAudioURL = request.externalAudioURL {
            audioOverride = try await audioFiles.resolveExternalRefineAudio(
                externalAudioURL,
                meetingID: request.meetingID)
        } else {
            audioOverride = nil
        }
        let refined = try await draft.execute(RefineMeetingRequest(
            detail: detail,
            languagePolicy: request.languagePolicy,
            audioOverride: audioOverride,
            progress: request.progress))
        let applied = try await apply.execute(ApplyRefinedMeetingRequest(
            meetingID: request.meetingID,
            draft: refined))
        return RefinePersistedMeetingResult(
            segmentCount: refined.segments.count,
            speakerCount: refined.speakers.count,
            transcriptRevision: applied.transcriptRevision)
    }
}

private struct RefinedTranscriptGenerationAttempt: Sendable {
    let id: GenerationRunID
    let meetingID: MeetingID
    let provider: RefineMeetingTranscriptionProvider
    let inputFingerprint: String
    let sourceTranscriptRevision: Int
    let channels: [AudioChannel]
    let languageHint: String?
    let vocabularyCount: Int
    let startedAt: Date

    func finish(
        outcome: GenerationRunOutcome,
        outputLanguage: String?,
        segments: [TranscriptSegment]?,
        at finishedAt: Date
    ) -> GenerationRun {
        GenerationRun(
            id: id,
            meetingID: meetingID,
            kind: .transcript,
            providerID: provider.providerID,
            modelID: provider.modelID,
            modelRevision: provider.modelRevision,
            inputFingerprint: inputFingerprint,
            configJSON: Self.json(Configuration(
                channels: channels.map(\.rawValue),
                languageMode: languageHint == nil ? "automatic" : "fixed",
                operation: "transcribe",
                sourceTranscriptRevision: sourceTranscriptRevision,
                vocabularyCount: vocabularyCount,
                workflow: "meeting-refine")),
            outputLanguage: outputLanguage,
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: outcome,
            metricsJSON: segments.map {
                Self.json(Metrics(
                    outputUTF8Bytes: $0.reduce(0) { $0 + $1.text.utf8.count },
                    segmentCount: $0.count,
                    speechMilliseconds: Int(($0.reduce(0.0) {
                        $0 + max(0, $1.endTime - $1.startTime)
                    } * 1_000).rounded())))
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
        let channels: [String]
        let languageMode: String
        let operation: String
        let sourceTranscriptRevision: Int
        let vocabularyCount: Int
        let workflow: String
    }

    private struct Metrics: Encodable {
        let outputUTF8Bytes: Int
        let segmentCount: Int
        let speechMilliseconds: Int
    }
}
