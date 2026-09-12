import ApplicationKit
import DiarizationKit
import Foundation
import IntelligenceKit
import PlatformKit
import PortavozCore
import StorageKit
import TranscriptionKit

struct ImportQueueFixture {
    let directory: URL
    let databaseURL: URL
    let source: URL
    let root: URL
    let store: MeetingStore
    let files: LocalAudioImportFiles

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        databaseURL = directory.appendingPathComponent("library.sqlite")
        source = directory.appendingPathComponent("Public synthetic.wav")
        root = directory.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 12, count: 1_024).write(to: source)
        store = try MeetingStore(databaseURL: databaseURL)
        files = LocalAudioImportFiles(root: root)
    }

    func admit(language: TranscriptLanguagePolicy = .automatic,
               summary: SummaryLanguagePolicy = .followSpokenLanguage) async throws -> AudioImportRequest {
        let input = try await files.prepareSelection(
            source, meetingID: MeetingID(), title: "Selected audio — audio elegido",
            preferences: .init(transcriptLanguage: language, summaryLanguage: summary,
                               summaryFallbackLanguage: .english, vocabulary: ["C++", "café"]))
        _ = try await store.enqueueAudioImports([input])
        return input
    }

    func worker(_ processor: ImportQueueProcessor, files override: (any AudioImportFiles)? = nil) -> ProcessAudioImports {
        ProcessAudioImports(store: store, files: override ?? files, makeProcessor: { processor },
                            summaries: ImportQueueSummary(), heartbeatInterval: .milliseconds(10))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

actor ImportQueueProcessor: ImportMeetingProcessor {
    struct State: Sendable {
        var releaseCount = 0
        var maximumConcurrent = 0
        var diarizerPreparationCount = 0
        var vocabularies: [[String]] = []
        var lateResults = 0
    }
    private var current = State()
    private var active = 0
    private var failFirst: Bool
    private let hold: AsyncStream<Void>?
    private let onTranscribe: @Sendable () -> Void

    init(failFirst: Bool = false, hold: AsyncStream<Void>? = nil,
         onTranscribe: @escaping @Sendable () -> Void = {}) {
        self.failFirst = failFirst
        self.hold = hold
        self.onTranscribe = onTranscribe
    }

    func state() -> State { current }
    func prepareTranscriber(progress: @escaping ImportMeetingProgressHandler) {
        active += 1
        current.maximumConcurrent = max(current.maximumConcurrent, active)
    }
    func prepareDiarizer() { current.diarizerPreparationCount += 1 }
    func transcribe(audio: ImportedMeetingAudio, meetingID: MeetingID,
                    languageHint: String?, vocabulary: [String]) async throws -> FileTranscription {
        current.vocabularies.append(vocabulary)
        onTranscribe()
        if failFirst { failFirst = false; throw ImportQueueTestError.transcription }
        if let hold {
            for await _ in hold { break }
            if Task.isCancelled { current.lateResults += 1 }
        }
        let text = languageHint == "es" ? "No envíes 2. Don’t." : "Don’t send 2. Café."
        return FileTranscription(text: text,
                                 segments: [.init(meetingID: meetingID, channel: .system, text: text,
                                                  language: languageHint, startTime: 0, endTime: 1)],
                                 audioDuration: 1, processingTime: 0)
    }
    func diarize(audio: ImportedMeetingAudio) -> [SpeakerTurn] { [] }
    func scheduleIdleRelease() { current.releaseCount += 1; active -= 1 }
}

private enum ImportQueueTestError: Error { case transcription }

struct ImportQueueSummary: ImportMeetingSummaryProviderResolver, ImportMeetingSummaryProvider {
    var providerID: String { "fixture" }
    var modelID: String { "scripted" }
    var modelRevision: String? { nil }
    func resolveImportMeetingSummaryProvider() -> ImportMeetingSummaryProviderResolution { .available(self) }
    func summarize(_ request: SummaryRequest) -> SummaryDraft {
        SummaryDraft(meetingID: request.meetingID, recipeID: request.recipe.id,
                     language: request.targetLanguage, markdown: "A synthetic summary.", actionItems: [],
                     fingerprint: SummaryFingerprint.compute(request: request, providerID: providerID))
    }
}

/// Holds the real native copy before publication, including when the old lease
/// has expired. It deliberately returns its late bytes rather than cooperating.
struct HeldImportAcquisition: AudioImportFiles {
    let native: LocalAudioImportFiles
    let hold: AsyncStream<Void>
    let didCopy: @Sendable () -> Void

    func prepareSelection(_ source: URL, meetingID: MeetingID, title: String,
                          preferences: ImportMeetingPreferencesSnapshot) async throws -> AudioImportRequest {
        try await native.prepareSelection(source, meetingID: meetingID, title: title, preferences: preferences)
    }
    func withAcquisitionAccess<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await native.withAcquisitionAccess(operation)
    }
    func copySelectedAudio(_ input: AudioImportRequest) async throws -> AudioImportCopy {
        let copy = try await native.copySelectedAudio(input)
        didCopy()
        for await _ in hold { break }
        return copy
    }
    func verifyOwnedAudio(_ input: AudioImportRequest) async throws -> AudioImportCopy {
        try await native.verifyOwnedAudio(input)
    }
}
