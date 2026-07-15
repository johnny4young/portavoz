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

/// Summary capability for the released best-effort import path.
public protocol ImportMeetingSummarizer: Sendable {
    func summarizeImportedMeeting(_ request: SummaryRequest) async throws -> SummaryDraft
}

/// Persistence boundary: the required aggregate is atomic; summary is optional.
public protocol ImportMeetingStore: Sendable {
    func installImportedMeeting(
        _ meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) async throws
    func saveImportedSummary(_ draft: SummaryDraft) async throws
}

extension MeetingStore: ImportMeetingStore {
    public func installImportedMeeting(
        _ meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) async throws {
        try await saveImportedMeeting(meeting, speakers: speakers, segments: segments)
    }

    public func saveImportedSummary(_ draft: SummaryDraft) async throws {
        _ = try await saveSummary(draft)
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
    private let summarizer: any ImportMeetingSummarizer
    private let makeMeetingID: @Sendable () -> MeetingID
    private let now: @Sendable () -> Date

    public init(
        audioFiles: any ImportMeetingAudioFiles,
        preferences: any ImportMeetingPreferences,
        processor: any ImportMeetingProcessor,
        store: any ImportMeetingStore,
        summarizer: any ImportMeetingSummarizer,
        makeMeetingID: @escaping @Sendable () -> MeetingID = { MeetingID() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.audioFiles = audioFiles
        self.preferences = preferences
        self.processor = processor
        self.store = store
        self.summarizer = summarizer
        self.makeMeetingID = makeMeetingID
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
        if let draft = try? await summarizer.summarizeImportedMeeting(request) {
            try? await store.saveImportedSummary(draft)
        }
    }
}

private struct ImportedMeetingContent: Sendable {
    let audioDuration: TimeInterval
    let segments: [TranscriptSegment]
    let speakers: [Speaker]
    let spokenLanguage: String?
}
