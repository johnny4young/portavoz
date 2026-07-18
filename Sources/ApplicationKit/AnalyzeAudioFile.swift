import DiarizationKit
import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit
import TranscriptionKit

/// Filesystem admission for command and document workflows. Concrete path
/// inspection stays in an executable adapter.
public protocol ApplicationInputFileAccess: Sendable {
    func isReadableFile(_ url: URL) async -> Bool
}

public enum AnalyzeAudioFileError: Error, Equatable, LocalizedError, Sendable {
    case inputFileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .inputFileNotFound(let path):
            "no such file: \(path)"
        }
    }
}

public enum AudioAnalysisEngine: String, Equatable, Sendable {
    case parakeet
    case whisper
}

public enum AudioAnalysisProgress: Equatable, Sendable {
    case downloadingModel(name: String, megabytes: Int)
    case downloadProgress(percent: Int, path: String)
    case loadingTranscriptionModel
    case installedModel(name: String)
    case transcribing(fileName: String, engine: AudioAnalysisEngine?)
    case diarizing(fileName: String?)
    case transcribingForAttribution
    case summarizing(language: String)
}

public typealias AudioAnalysisProgressHandler =
    @Sendable (AudioAnalysisProgress) async -> Void

public protocol AudioFileTranscriptionProcessor: Sendable {
    func transcribe(
        fileURL: URL,
        engine: AudioAnalysisEngine,
        hints: TranscriptionHints,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> FileTranscription
}

public struct TranscribeAudioFileRequest: Sendable {
    public let fileURL: URL
    public let engine: AudioAnalysisEngine
    public let language: String?
    public let vocabulary: [String]
    public let progress: AudioAnalysisProgressHandler

    public init(
        fileURL: URL,
        engine: AudioAnalysisEngine,
        language: String?,
        vocabulary: [String] = [],
        progress: @escaping AudioAnalysisProgressHandler = { _ in }
    ) {
        self.fileURL = fileURL
        self.engine = engine
        self.language = language
        self.vocabulary = vocabulary
        self.progress = progress
    }
}

public struct TranscribeAudioFileResult: Sendable {
    public let segments: [TranscriptSegment]
    public let audioDuration: TimeInterval
    public let processingTime: TimeInterval
    public let speedFactor: Double

    public init(_ transcription: FileTranscription) {
        segments = transcription.segments
        audioDuration = transcription.audioDuration
        processingTime = transcription.processingTime
        speedFactor = transcription.speedFactor
    }
}

/// One file transcription with path admission and model work behind ports.
public struct TranscribeAudioFile: ApplicationUseCase {
    private let files: any ApplicationInputFileAccess
    private let processor: any AudioFileTranscriptionProcessor

    public init(
        files: any ApplicationInputFileAccess,
        processor: any AudioFileTranscriptionProcessor
    ) {
        self.files = files
        self.processor = processor
    }

    public func execute(
        _ request: TranscribeAudioFileRequest
    ) async throws -> TranscribeAudioFileResult {
        guard await files.isReadableFile(request.fileURL) else {
            throw AnalyzeAudioFileError.inputFileNotFound(request.fileURL.path)
        }
        await request.progress(.transcribing(
            fileName: request.fileURL.lastPathComponent,
            engine: request.engine))
        let transcription = try await processor.transcribe(
            fileURL: request.fileURL,
            engine: request.engine,
            hints: TranscriptionHints(
                language: request.language,
                vocabulary: request.vocabulary),
            progress: request.progress)
        return TranscribeAudioFileResult(transcription)
    }
}

public protocol AudioFileDiarizationProcessor: Sendable {
    func prepare(
        clusteringThreshold: Float,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws
    func diarize(
        fileURL: URL,
        clusteringThreshold: Float,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> [SpeakerTurn]
    func transcribeForAttribution(
        fileURL: URL,
        hints: TranscriptionHints,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> FileTranscription
}

public struct DiarizeAudioFileRequest: Sendable {
    public let fileURL: URL
    public let clusteringThreshold: Float
    public let attributeTranscript: Bool
    public let language: String?
    public let progress: AudioAnalysisProgressHandler

    public init(
        fileURL: URL,
        clusteringThreshold: Float,
        attributeTranscript: Bool,
        language: String?,
        progress: @escaping AudioAnalysisProgressHandler = { _ in }
    ) {
        self.fileURL = fileURL
        self.clusteringThreshold = clusteringThreshold
        self.attributeTranscript = attributeTranscript
        self.language = language
        self.progress = progress
    }
}

public struct DiarizeAudioFileResult: Sendable {
    public let turns: [SpeakerTurn]
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let elapsed: TimeInterval

    public init(
        turns: [SpeakerTurn],
        speakers: [Speaker],
        segments: [TranscriptSegment],
        elapsed: TimeInterval
    ) {
        self.turns = turns
        self.speakers = speakers
        self.segments = segments
        self.elapsed = elapsed
    }
}

/// Diarization and optional attribution. The use case owns ordering, identity,
/// and elapsed-time policy while the adapter owns model construction.
public struct DiarizeAudioFile: ApplicationUseCase {
    private let files: any ApplicationInputFileAccess
    private let processor: any AudioFileDiarizationProcessor
    private let makeMeetingID: @Sendable () -> MeetingID
    private let now: @Sendable () -> Date

    public init(
        files: any ApplicationInputFileAccess,
        processor: any AudioFileDiarizationProcessor,
        makeMeetingID: @escaping @Sendable () -> MeetingID = { MeetingID() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.files = files
        self.processor = processor
        self.makeMeetingID = makeMeetingID
        self.now = now
    }

    public func execute(_ request: DiarizeAudioFileRequest) async throws -> DiarizeAudioFileResult {
        guard await files.isReadableFile(request.fileURL) else {
            throw AnalyzeAudioFileError.inputFileNotFound(request.fileURL.path)
        }
        try await processor.prepare(
            clusteringThreshold: request.clusteringThreshold,
            progress: request.progress)
        await request.progress(.diarizing(fileName: request.fileURL.lastPathComponent))
        let started = now()
        let turns = try await processor.diarize(
            fileURL: request.fileURL,
            clusteringThreshold: request.clusteringThreshold,
            progress: request.progress)
        let elapsed = now().timeIntervalSince(started)
        guard request.attributeTranscript else {
            return DiarizeAudioFileResult(
                turns: turns,
                speakers: [],
                segments: [],
                elapsed: elapsed)
        }

        await request.progress(.transcribingForAttribution)
        let meetingID = makeMeetingID()
        let transcription = try await processor.transcribeForAttribution(
            fileURL: request.fileURL,
            hints: TranscriptionHints(language: request.language, meetingID: meetingID),
            progress: request.progress)
        let attribution = SpeakerAttributor.attribute(
            segments: transcription.segments,
            turns: turns,
            meetingID: meetingID)
        return DiarizeAudioFileResult(
            turns: turns,
            speakers: attribution.speakers,
            segments: attribution.segments,
            elapsed: elapsed)
    }
}

public protocol AudioFileSummaryProcessor: Sendable {
    func prepare(progress: @escaping AudioAnalysisProgressHandler) async throws
    func transcribe(
        fileURL: URL,
        hints: TranscriptionHints,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> FileTranscription
    func diarize(
        fileURL: URL,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> [SpeakerTurn]
    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft
}

public protocol AnalyzedMeetingStore: Sendable {
    func saveAnalyzedMeeting(
        _ meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) async throws
    func saveAnalyzedSummary(_ draft: SummaryDraft) async throws -> Int
}

extension MeetingStore: AnalyzedMeetingStore {
    public func saveAnalyzedMeeting(
        _ meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) async throws {
        try await save(meeting)
        try await save(speakers)
        try await save(segments)
    }

    public func saveAnalyzedSummary(_ draft: SummaryDraft) async throws -> Int {
        try await saveSummary(draft)
    }
}

public struct SummarizeAudioFileRequest: Sendable {
    public let fileURL: URL
    public let spokenLanguage: String?
    public let outputLanguage: String
    public let glossary: [String]
    public let progress: AudioAnalysisProgressHandler

    public init(
        fileURL: URL,
        spokenLanguage: String?,
        outputLanguage: String,
        glossary: [String],
        progress: @escaping AudioAnalysisProgressHandler = { _ in }
    ) {
        self.fileURL = fileURL
        self.spokenLanguage = spokenLanguage
        self.outputLanguage = outputLanguage
        self.glossary = glossary
        self.progress = progress
    }
}

public struct SummarizeAudioFileResult: Sendable {
    public let meetingID: MeetingID
    public let attribution: SpeakerAttributor.Attribution
    public let draft: SummaryDraft
    public let elapsed: TimeInterval
    public let savedVersion: Int?

    public init(
        meetingID: MeetingID,
        attribution: SpeakerAttributor.Attribution,
        draft: SummaryDraft,
        elapsed: TimeInterval,
        savedVersion: Int?
    ) {
        self.meetingID = meetingID
        self.attribution = attribution
        self.draft = draft
        self.elapsed = elapsed
        self.savedVersion = savedVersion
    }
}

/// Transcribe, diarize, attribute, optionally admit the meeting before remote
/// egress, summarize, and optionally persist the immutable summary.
public struct SummarizeAudioFile: ApplicationUseCase {
    private let files: any ApplicationInputFileAccess
    private let processor: any AudioFileSummaryProcessor
    private let store: (any AnalyzedMeetingStore)?
    private let makeMeetingID: @Sendable () -> MeetingID
    private let now: @Sendable () -> Date

    public init(
        files: any ApplicationInputFileAccess,
        processor: any AudioFileSummaryProcessor,
        store: (any AnalyzedMeetingStore)? = nil,
        makeMeetingID: @escaping @Sendable () -> MeetingID = { MeetingID() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.files = files
        self.processor = processor
        self.store = store
        self.makeMeetingID = makeMeetingID
        self.now = now
    }

    public func execute(_ request: SummarizeAudioFileRequest) async throws -> SummarizeAudioFileResult {
        guard await files.isReadableFile(request.fileURL) else {
            throw AnalyzeAudioFileError.inputFileNotFound(request.fileURL.path)
        }
        let meetingID = makeMeetingID()
        try await processor.prepare(progress: request.progress)
        await request.progress(.transcribing(
            fileName: request.fileURL.lastPathComponent,
            engine: .parakeet))
        let transcription = try await processor.transcribe(
            fileURL: request.fileURL,
            hints: TranscriptionHints(language: request.spokenLanguage, meetingID: meetingID),
            progress: request.progress)
        await request.progress(.diarizing(fileName: nil))
        let turns = try await processor.diarize(
            fileURL: request.fileURL,
            progress: request.progress)
        let attribution = SpeakerAttributor.attribute(
            segments: transcription.segments,
            turns: turns,
            meetingID: meetingID)

        if let store {
            let finishedAt = now()
            try await store.saveAnalyzedMeeting(
                Meeting(
                    id: meetingID,
                    title: request.fileURL.deletingPathExtension().lastPathComponent,
                    startedAt: finishedAt.addingTimeInterval(-transcription.audioDuration),
                    endedAt: finishedAt,
                    language: SpokenLanguageDetector.homogeneousLanguage(
                        in: attribution.segments)),
                speakers: attribution.speakers,
                segments: attribution.segments)
        }

        await request.progress(.summarizing(language: request.outputLanguage))
        let summaryRequest = SummaryRequest(
            meetingID: meetingID,
            segments: attribution.segments,
            speakers: attribution.speakers,
            recipe: .general,
            targetLanguage: request.outputLanguage,
            glossary: request.glossary)
        let started = now()
        let draft = try await processor.summarize(summaryRequest)
        let elapsed = now().timeIntervalSince(started)
        let version = try await store?.saveAnalyzedSummary(draft)
        return SummarizeAudioFileResult(
            meetingID: meetingID,
            attribution: attribution,
            draft: draft,
            elapsed: elapsed,
            savedVersion: version)
    }
}
