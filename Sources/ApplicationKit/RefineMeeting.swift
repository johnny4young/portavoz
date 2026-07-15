import DiarizationKit
import Foundation
import PortavozCore
import StorageKit
import TranscriptionKit

/// One persisted channel considered by the quality re-pass.
public struct RefineMeetingAudioChannel: Equatable, Sendable {
    public let fileURL: URL
    public let isSilent: Bool

    public init(fileURL: URL, isSilent: Bool) {
        self.fileURL = fileURL
        self.isSilent = isSilent
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
    func resolveRefineAudio(_ relativeDirectory: String) async throws -> RefineMeetingAudio
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
    case downloadingWhisper(size: String, percent: Int)
    case transcribingParticipants
    case transcribingMicrophone
    case identifyingSpeakers
}

public typealias RefineMeetingProgressHandler =
    @Sendable (RefineMeetingProgress) async -> Void

/// Concrete Whisper/diarizer ownership remains in the app composition root.
public protocol RefineMeetingProcessor: Sendable {
    func prepare(progress: @escaping RefineMeetingProgressHandler) async throws
    func transcribe(
        fileURL: URL,
        hints: TranscriptionHints,
        channel: AudioChannel
    ) async throws -> FileTranscription
    func diarize(fileURL: URL) async throws -> [SpeakerTurn]
    func scheduleIdleRelease() async
}

public enum RefineMeetingError: Error, Equatable, Sendable {
    case audioNotRetained
    case audioUnavailable
}

public struct RefineMeetingRequest: Sendable {
    public let detail: MeetingDetail
    public let languagePolicy: TranscriptLanguagePolicy?
    public let progress: RefineMeetingProgressHandler

    public init(
        detail: MeetingDetail,
        languagePolicy: TranscriptLanguagePolicy? = nil,
        progress: @escaping RefineMeetingProgressHandler = { _ in }
    ) {
        self.detail = detail
        self.languagePolicy = languagePolicy
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

    public init(
        audioFiles: any RefineMeetingAudioFiles,
        preferences: any RefineMeetingPreferences,
        processor: any RefineMeetingProcessor
    ) {
        self.audioFiles = audioFiles
        self.preferences = preferences
        self.processor = processor
    }

    public func execute(_ request: RefineMeetingRequest) async throws -> RefineDraft {
        guard let relativeDirectory = request.detail.meeting.audioDirectory else {
            throw RefineMeetingError.audioNotRetained
        }
        let audio = try await audioFiles.resolveRefineAudio(relativeDirectory)
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
        let segments = try await transcribe(audio: audio, hints: hints, progress: request.progress)
        let turns = try await speakerTurns(audio: audio, progress: request.progress)
        let attribution = SpeakerAttributor.attribute(
            segments: segments,
            turns: turns,
            meetingID: detail.meeting.id)
        let oldSpeech = detail.segments.reduce(0) {
            $0 + ($1.endTime - $1.startTime)
        }
        let meetingSeconds = detail.meeting.endedAt.map {
            $0.timeIntervalSince(detail.meeting.startedAt)
        }
        return RefineDraft(
            sourceTranscriptRevision: detail.meeting.transcriptRevision,
            language: SpokenLanguageDetector.homogeneousLanguage(
                in: attribution.segments),
            speakers: attribution.speakers,
            segments: attribution.segments,
            oldSegmentCount: detail.segments.count,
            oldSpeakerCount: detail.speakers.count,
            oldSpeechSeconds: oldSpeech,
            meetingSeconds: meetingSeconds)
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
            segments.append(contentsOf: result.segments)
            try Task.checkCancellation()
        }
        if let microphone = audio.microphone, !microphone.isSilent {
            await progress(.transcribingMicrophone)
            let result = try await processor.transcribe(
                fileURL: microphone.fileURL,
                hints: hints,
                channel: .microphone)
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
        segments: [TranscriptSegment]
    ) async throws
    func replaceRefinedCompanionCards(
        _ cards: [CompanionCard],
        for meetingID: MeetingID
    ) async throws
}

extension MeetingStore: RefineMeetingStore {
    public func installRefinedCast(
        meetingID: MeetingID,
        expectedTranscriptRevision: Int,
        language: String?,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) async throws {
        try await applyRefinedCast(
            for: meetingID,
            expectedTranscriptRevision: expectedTranscriptRevision,
            language: language,
            speakers: speakers,
            segments: segments)
    }

    public func replaceRefinedCompanionCards(
        _ cards: [CompanionCard],
        for meetingID: MeetingID
    ) async throws {
        try await replaceCompanionCards(cards, for: meetingID)
    }
}

public struct RefineMeetingCompanionRefresh: Sendable {
    public let cards: [CompanionCard]
    public let completed: Bool

    public init(cards: [CompanionCard], completed: Bool) {
        self.cards = cards
        self.completed = completed
    }
}

/// Companion model capability; platform/version/preference checks stay private
/// to the app adapter.
public protocol RefineMeetingCompanion: Sendable {
    func isRefreshAvailable() async -> Bool
    func refresh(
        segments: [TranscriptSegment],
        meetingID: MeetingID
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
            segments: request.draft.segments)

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
            meetingID: request.meetingID)
        guard refreshed.completed else { return .preserved }
        do {
            try await store.replaceRefinedCompanionCards(
                refreshed.cards,
                for: request.meetingID)
            return .replaced(count: refreshed.cards.count)
        } catch {
            return .persistenceFailed
        }
    }
}

public struct RefineMeetingUseCases: Sendable {
    public let draft: RefineMeeting
    public let apply: ApplyRefinedMeeting

    public init(
        audioFiles: any RefineMeetingAudioFiles,
        preferences: any RefineMeetingPreferences,
        processor: any RefineMeetingProcessor,
        store: any RefineMeetingStore,
        companion: any RefineMeetingCompanion
    ) {
        draft = RefineMeeting(
            audioFiles: audioFiles,
            preferences: preferences,
            processor: processor)
        apply = ApplyRefinedMeeting(store: store, companion: companion)
    }
}
