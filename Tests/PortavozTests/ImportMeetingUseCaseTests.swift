import ApplicationKit
import DiarizationKit
import Foundation
import GRDB
import IntelligenceKit
import PortavozCore
import TranscriptionKit
import XCTest

@testable import StorageKit

final class ImportMeetingUseCaseTests: XCTestCase {
    func testHappyPathPreservesOrderPoliciesAttributionSummaryAndRelease() async throws {
        let fixture = ImportFixture()
        let dependencies = ImportDependencies(
            preferences: .init(
                transcriptLanguage: .fixed(.spanish),
                summaryLanguage: .followSpokenLanguage,
                summaryFallbackLanguage: .english,
                vocabulary: ["Portavoz"]),
            transcription: fixture.spanishTranscription,
            turns: [SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 8)])
        let useCase = fixture.useCase(dependencies: dependencies)

        let result = try await useCase(fixture.request(dependencies: dependencies))

        let state = await dependencies.state()
        XCTAssertEqual(result, fixture.meetingID)
        XCTAssertEqual(state.progress, [
            .preparingModels,
            .downloadingWhisper(size: "1.6 GB", percent: 42),
            .transcribing,
            .identifyingSpeakers,
            .generatingSummary,
        ])
        XCTAssertEqual(state.events, [
            "preferences", "copy", "prepare-transcriber", "prepare-diarizer-1",
            "transcribe", "prepare-diarizer-2", "diarize", "install",
            "summarize", "save-summary", "release",
        ])
        XCTAssertEqual(state.copiedSource, fixture.source)
        XCTAssertEqual(state.transcriptionLanguageHint, "es")
        XCTAssertEqual(state.transcriptionVocabulary, ["Portavoz"])
        XCTAssertEqual(state.installed?.meeting.id, fixture.meetingID)
        XCTAssertEqual(state.installed?.meeting.title, fixture.title)
        XCTAssertEqual(state.installed?.meeting.startedAt, fixture.now)
        XCTAssertEqual(
            state.installed?.meeting.endedAt,
            fixture.now.addingTimeInterval(fixture.spanishTranscription.audioDuration))
        XCTAssertEqual(state.installed?.meeting.language, "es")
        XCTAssertEqual(state.installed?.meeting.audioDirectory, fixture.audio.relativeDirectory)
        XCTAssertEqual(state.installed?.speakers.map(\.label), ["S1"])
        XCTAssertEqual(state.installed?.segments.map(\.text), [
            "Primero revisamos el presupuesto.",
            "Después acordamos el lanzamiento.",
        ])
        XCTAssertTrue(state.installed?.segments.allSatisfy { $0.speakerID != nil } == true)
        XCTAssertEqual(state.summaryRequest?.targetLanguage, "es")
        XCTAssertEqual(state.summaryRequest?.glossary, ["Portavoz"])
        XCTAssertEqual(state.savedSummary?.meetingID, fixture.meetingID)
        XCTAssertEqual(state.releaseCount, 1)
        XCTAssertTrue(state.discardedAudio.isEmpty)
    }

    func testMixedTranscriptKeepsRecognitionAutomaticAndUsesSummaryFallback() async throws {
        let fixture = ImportFixture()
        let mixed = FileTranscription(
            text: "Hola. We agree.",
            segments: [
                fixture.segment(
                    text: "Esta intervención permanece en español.",
                    language: "es",
                    start: 0,
                    end: 3),
                fixture.segment(
                    text: "This contribution remains in English.",
                    language: "en",
                    start: 3,
                    end: 6),
            ],
            audioDuration: 6,
            processingTime: 1)
        let dependencies = ImportDependencies(
            preferences: .init(
                transcriptLanguage: .automatic,
                summaryLanguage: .followSpokenLanguage,
                summaryFallbackLanguage: .spanish,
                vocabulary: []),
            transcription: mixed,
            turns: [])

        _ = try await fixture.useCase(dependencies: dependencies)(
            fixture.request(dependencies: dependencies))

        let state = await dependencies.state()
        XCTAssertNil(state.transcriptionLanguageHint)
        XCTAssertNil(state.installed?.meeting.language)
        XCTAssertEqual(state.summaryRequest?.targetLanguage, "es")
        XCTAssertTrue(state.installed?.segments.allSatisfy { $0.speakerID == nil } == true)
    }

    func testDiarizerReloadFailureStillUsesAnAvailableEngine() async throws {
        let fixture = ImportFixture()
        let dependencies = ImportDependencies(
            transcription: fixture.spanishTranscription,
            failures: [.secondDiarizerPreparation])

        let meetingID = try await fixture.useCase(dependencies: dependencies)(
            fixture.request(dependencies: dependencies))

        let state = await dependencies.state()
        XCTAssertEqual(meetingID, fixture.meetingID)
        XCTAssertEqual(state.installed?.speakers.map(\.label), ["S1"])
        XCTAssertTrue(state.installed?.segments.allSatisfy { $0.speakerID != nil } == true)
        XCTAssertTrue(state.events.contains("diarize"))
        XCTAssertEqual(state.releaseCount, 1)
        XCTAssertTrue(state.discardedAudio.isEmpty)
    }

    func testDiarizationFailureDegradesToUnattributedTranscript() async throws {
        let fixture = ImportFixture()
        let dependencies = ImportDependencies(
            transcription: fixture.spanishTranscription,
            failures: [.diarization])

        let meetingID = try await fixture.useCase(dependencies: dependencies)(
            fixture.request(dependencies: dependencies))

        let state = await dependencies.state()
        XCTAssertEqual(meetingID, fixture.meetingID)
        XCTAssertTrue(state.installed?.speakers.isEmpty == true)
        XCTAssertTrue(state.installed?.segments.allSatisfy { $0.speakerID == nil } == true)
        XCTAssertEqual(state.releaseCount, 1)
        XCTAssertTrue(state.discardedAudio.isEmpty)
    }

    func testSummaryGenerationFailureDoesNotDiscardCommittedMeeting() async throws {
        let fixture = ImportFixture()
        let dependencies = ImportDependencies(
            transcription: fixture.spanishTranscription,
            failures: [.summaryGeneration])

        _ = try await fixture.useCase(dependencies: dependencies)(
            fixture.request(dependencies: dependencies))

        let state = await dependencies.state()
        XCTAssertNotNil(state.installed)
        XCTAssertNil(state.savedSummary)
        XCTAssertTrue(state.discardedAudio.isEmpty)
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testSummaryPersistenceFailureDoesNotFailCommittedMeeting() async throws {
        let fixture = ImportFixture()
        let dependencies = ImportDependencies(
            transcription: fixture.spanishTranscription,
            failures: [.summaryPersistence])

        let meetingID = try await fixture.useCase(dependencies: dependencies)(
            fixture.request(dependencies: dependencies))

        let state = await dependencies.state()
        XCTAssertEqual(meetingID, fixture.meetingID)
        XCTAssertNotNil(state.installed)
        XCTAssertNil(state.savedSummary)
        XCTAssertTrue(state.discardedAudio.isEmpty)
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testTranscriberPreparationFailureDiscardsCopyWithoutSchedulingRelease() async {
        let fixture = ImportFixture()
        let dependencies = ImportDependencies(
            transcription: fixture.spanishTranscription,
            failures: [.transcriberPreparation])

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.useCase(dependencies: dependencies)(
                fixture.request(dependencies: dependencies))
        }

        let state = await dependencies.state()
        XCTAssertEqual(state.discardedAudio, [fixture.audio])
        XCTAssertEqual(state.releaseCount, 0)
        XCTAssertNil(state.installed)
    }

    func testRequiredDiarizerPreparationFailureDiscardsCopyAndSchedulesRelease() async {
        let fixture = ImportFixture()
        let dependencies = ImportDependencies(
            transcription: fixture.spanishTranscription,
            failures: [.firstDiarizerPreparation])

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.useCase(dependencies: dependencies)(
                fixture.request(dependencies: dependencies))
        }

        let state = await dependencies.state()
        XCTAssertEqual(state.discardedAudio, [fixture.audio])
        XCTAssertEqual(state.releaseCount, 1)
        XCTAssertNil(state.installed)
    }

    func testTranscriptionOrStorageFailureRollsBackCopiedAudio() async {
        for failure in [ImportFailure.transcription, .aggregatePersistence] {
            let fixture = ImportFixture()
            let dependencies = ImportDependencies(
                transcription: fixture.spanishTranscription,
                failures: [failure])

            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.useCase(dependencies: dependencies)(
                    fixture.request(dependencies: dependencies))
            }

            let state = await dependencies.state()
            XCTAssertEqual(state.discardedAudio, [fixture.audio], "failure: \(failure)")
            XCTAssertEqual(state.releaseCount, 1, "failure: \(failure)")
        }
    }

    func testRollbackFailureDoesNotMaskRequiredImportFailure() async {
        let fixture = ImportFixture()
        let dependencies = ImportDependencies(
            transcription: fixture.spanishTranscription,
            failures: [.transcription, .audioDiscard])

        do {
            _ = try await fixture.useCase(dependencies: dependencies)(
                fixture.request(dependencies: dependencies))
            XCTFail("transcription failure must escape")
        } catch {
            XCTAssertTrue(error is ImportDependencyError)
        }
        let state = await dependencies.state()
        XCTAssertEqual(state.discardAttempts, 1)
    }

    func testRealStoreAdapterPersistsAggregateAndSummary() async throws {
        let fixture = ImportFixture()
        let store = try MeetingStore.inMemory()
        let dependencies = ImportDependencies(transcription: fixture.spanishTranscription)
        let useCase = ImportMeeting(
            audioFiles: dependencies,
            preferences: dependencies,
            processor: dependencies,
            store: store,
            summarizer: dependencies,
            makeMeetingID: { fixture.meetingID },
            now: { fixture.now })

        _ = try await useCase(fixture.request(dependencies: dependencies))

        let detail = try await store.detail(fixture.meetingID)
        let summary = try await store.summary(fixture.meetingID)
        XCTAssertEqual(detail?.meeting.title, fixture.title)
        XCTAssertEqual(detail?.speakers.map(\.label), ["S1"])
        XCTAssertEqual(detail?.segments.count, 2)
        XCTAssertEqual(summary?.draft.markdown, "# Imported summary")
    }

    func testImportedAggregateTransactionRollsBackWhenChildInsertFails() async throws {
        let fixture = ImportFixture()
        let store = try MeetingStore.inMemory()
        let speaker = Speaker(meetingID: fixture.meetingID, label: "S1")
        var segment = fixture.spanishTranscription.segments[0]
        segment.speakerID = speaker.id
        let meeting = Meeting(
            id: fixture.meetingID,
            title: fixture.title,
            startedAt: fixture.now,
            endedAt: fixture.now.addingTimeInterval(8),
            language: "es",
            audioDirectory: fixture.audio.relativeDirectory)
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_import_segment
                BEFORE INSERT ON segment
                BEGIN
                    SELECT RAISE(ABORT, 'injected import child failure');
                END
                """)
        }

        do {
            try await store.saveImportedMeeting(
                meeting,
                speakers: [speaker],
                segments: [segment])
            XCTFail("child failure must reject the whole imported aggregate")
        } catch {
            let detail = try await store.detail(fixture.meetingID)
            let meetings = try await store.meetings()
            XCTAssertNil(detail)
            XCTAssertFalse(meetings.contains { $0.id == fixture.meetingID })
        }
    }

    func testImportedAggregateRejectsChildrenOutsideItsOwnershipBoundary() async throws {
        let fixture = ImportFixture()
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            id: fixture.meetingID,
            title: fixture.title,
            startedAt: fixture.now,
            endedAt: fixture.now.addingTimeInterval(8),
            language: "es",
            audioDirectory: fixture.audio.relativeDirectory)
        let foreignSpeaker = Speaker(meetingID: MeetingID(), label: "S1")
        var unknownSpeakerSegment = fixture.spanishTranscription.segments[0]
        unknownSpeakerSegment.speakerID = SpeakerID()

        for children in [
            ([foreignSpeaker], [TranscriptSegment]()),
            ([Speaker](), [unknownSpeakerSegment]),
        ] {
            do {
                try await store.saveImportedMeeting(
                    meeting,
                    speakers: children.0,
                    segments: children.1)
                XCTFail("foreign imported children must be rejected")
            } catch let error as StorageError {
                guard case .invalidImportedMeeting = error else {
                    return XCTFail("unexpected storage error: \(error)")
                }
            }
        }

        let meetings = try await store.meetings()
        XCTAssertTrue(meetings.isEmpty)
    }
}

private struct ImportFixture: Sendable {
    let meetingID = MeetingID(rawValue: UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!)
    let source = URL(fileURLWithPath: "/tmp/quarterly.m4a")
    let title = "Imported · quarterly"
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    var audio: ImportedMeetingAudio {
        ImportedMeetingAudio(
            fileURL: URL(fileURLWithPath: "/scratch/Audio/\(meetingID.rawValue)/system.m4a"),
            relativeDirectory: "Audio/\(meetingID.rawValue.uuidString)")
    }

    var spanishTranscription: FileTranscription {
        FileTranscription(
            text: "Primero revisamos. Después acordamos.",
            segments: [
                segment(
                    text: "Después acordamos el lanzamiento.",
                    language: "es",
                    start: 4,
                    end: 8),
                segment(
                    text: "Primero revisamos el presupuesto.",
                    language: "es",
                    start: 0,
                    end: 4),
            ],
            audioDuration: 8,
            processingTime: 1)
    }

    func segment(
        text: String,
        language: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID,
            channel: .system,
            text: text,
            language: language,
            startTime: start,
            endTime: end,
            isFinal: true)
    }

    func request(dependencies: ImportDependencies) -> ImportMeetingRequest {
        ImportMeetingRequest(sourceURL: source, title: title) { phase in
            await dependencies.record(progress: phase)
        }
    }

    func useCase(dependencies: ImportDependencies) -> ImportMeeting {
        ImportMeeting(
            audioFiles: dependencies,
            preferences: dependencies,
            processor: dependencies,
            store: dependencies,
            summarizer: dependencies,
            makeMeetingID: { meetingID },
            now: { now })
    }
}

private enum ImportFailure: Hashable, Sendable {
    case transcriberPreparation
    case firstDiarizerPreparation
    case secondDiarizerPreparation
    case transcription
    case diarization
    case aggregatePersistence
    case summaryGeneration
    case summaryPersistence
    case audioDiscard
}

private struct ImportDependencyError: Error {}

private struct InstalledImport: Sendable {
    let meeting: Meeting
    let speakers: [Speaker]
    let segments: [TranscriptSegment]
}

private struct ImportDependencyState: Sendable {
    let events: [String]
    let progress: [ImportMeetingProgress]
    let copiedSource: URL?
    let discardedAudio: [ImportedMeetingAudio]
    let discardAttempts: Int
    let transcriptionLanguageHint: String?
    let transcriptionVocabulary: [String]
    let installed: InstalledImport?
    let summaryRequest: SummaryRequest?
    let savedSummary: SummaryDraft?
    let releaseCount: Int
}

private actor ImportDependencies:
    ImportMeetingAudioFiles,
    ImportMeetingPreferences,
    ImportMeetingProcessor,
    ImportMeetingStore,
    ImportMeetingSummarizer
{
    private let preferences: ImportMeetingPreferencesSnapshot
    private let transcription: FileTranscription
    private let turns: [SpeakerTurn]
    private let failures: Set<ImportFailure>
    private var events: [String] = []
    private var progressEvents: [ImportMeetingProgress] = []
    private var copiedSource: URL?
    private var discardedAudio: [ImportedMeetingAudio] = []
    private var discardAttempts = 0
    private var diarizerPreparations = 0
    private var transcriptionLanguageHint: String?
    private var transcriptionVocabulary: [String] = []
    private var installed: InstalledImport?
    private var summaryRequest: SummaryRequest?
    private var savedSummary: SummaryDraft?
    private var releaseCount = 0

    init(
        preferences: ImportMeetingPreferencesSnapshot = .init(
            transcriptLanguage: .automatic,
            summaryLanguage: .followSpokenLanguage,
            summaryFallbackLanguage: .english,
            vocabulary: []),
        transcription: FileTranscription,
        turns: [SpeakerTurn] = [
            SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 8),
        ],
        failures: Set<ImportFailure> = []
    ) {
        self.preferences = preferences
        self.transcription = transcription
        self.turns = turns
        self.failures = failures
    }

    func record(progress: ImportMeetingProgress) {
        progressEvents.append(progress)
    }

    func importMeetingPreferences() -> ImportMeetingPreferencesSnapshot {
        events.append("preferences")
        return preferences
    }

    func copySystemAudio(
        from source: URL,
        meetingID: MeetingID
    ) -> ImportedMeetingAudio {
        events.append("copy")
        copiedSource = source
        return ImportedMeetingAudio(
            fileURL: URL(fileURLWithPath: "/scratch/Audio/\(meetingID.rawValue)/system.m4a"),
            relativeDirectory: "Audio/\(meetingID.rawValue.uuidString)")
    }

    func discardImportedAudio(_ audio: ImportedMeetingAudio) throws {
        events.append("discard")
        discardAttempts += 1
        if failures.contains(.audioDiscard) { throw ImportDependencyError() }
        discardedAudio.append(audio)
    }

    func prepareTranscriber(
        progress: @escaping ImportMeetingProgressHandler
    ) async throws {
        events.append("prepare-transcriber")
        if failures.contains(.transcriberPreparation) { throw ImportDependencyError() }
        await progress(.downloadingWhisper(size: "1.6 GB", percent: 42))
    }

    func prepareDiarizer() throws {
        diarizerPreparations += 1
        events.append("prepare-diarizer-\(diarizerPreparations)")
        if diarizerPreparations == 1, failures.contains(.firstDiarizerPreparation) {
            throw ImportDependencyError()
        }
        if diarizerPreparations == 2, failures.contains(.secondDiarizerPreparation) {
            throw ImportDependencyError()
        }
    }

    func transcribe(
        audio: ImportedMeetingAudio,
        meetingID: MeetingID,
        languageHint: String?,
        vocabulary: [String]
    ) throws -> FileTranscription {
        events.append("transcribe")
        transcriptionLanguageHint = languageHint
        transcriptionVocabulary = vocabulary
        if failures.contains(.transcription) { throw ImportDependencyError() }
        return transcription
    }

    func diarize(audio: ImportedMeetingAudio) throws -> [SpeakerTurn] {
        events.append("diarize")
        if failures.contains(.diarization) { throw ImportDependencyError() }
        return turns
    }

    func scheduleIdleRelease() {
        events.append("release")
        releaseCount += 1
    }

    func installImportedMeeting(
        _ meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) throws {
        events.append("install")
        if failures.contains(.aggregatePersistence) { throw ImportDependencyError() }
        installed = InstalledImport(meeting: meeting, speakers: speakers, segments: segments)
    }

    func summarizeImportedMeeting(_ request: SummaryRequest) throws -> SummaryDraft {
        events.append("summarize")
        summaryRequest = request
        if failures.contains(.summaryGeneration) { throw ImportDependencyError() }
        return SummaryDraft(
            meetingID: request.meetingID,
            recipeID: request.recipe.id,
            language: request.targetLanguage,
            markdown: "# Imported summary",
            actionItems: [])
    }

    func saveImportedSummary(_ draft: SummaryDraft) throws {
        events.append("save-summary")
        if failures.contains(.summaryPersistence) { throw ImportDependencyError() }
        savedSummary = draft
    }

    func state() -> ImportDependencyState {
        ImportDependencyState(
            events: events,
            progress: progressEvents,
            copiedSource: copiedSource,
            discardedAudio: discardedAudio,
            discardAttempts: discardAttempts,
            transcriptionLanguageHint: transcriptionLanguageHint,
            transcriptionVocabulary: transcriptionVocabulary,
            installed: installed,
            summaryRequest: summaryRequest,
            savedSummary: savedSummary,
            releaseCount: releaseCount)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
