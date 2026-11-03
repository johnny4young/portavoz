import ApplicationKit
import DiarizationKit
import Foundation
import IntelligenceKit
import PortavozCore
import TranscriptionKit
import XCTest

final class AnalyzeAudioFileUseCaseTests: XCTestCase {
    func testTranscribeRejectsUnreadableInputBeforePreparingModels() async {
        let processor = AudioTranscriptionProcessorSpy()
        let useCase = TranscribeAudioFile(
            files: AudioInputFilesFake(readable: false),
            processor: processor)

        await assertThrows(AnalyzeAudioFileError.inputFileNotFound("/missing.wav")) {
            _ = try await useCase.execute(TranscribeAudioFileRequest(
                fileURL: URL(fileURLWithPath: "/missing.wav"),
                engine: .whisper,
                language: "es",
                vocabulary: ["Portavoz"]))
        }
        let callCount = await processor.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testTranscribeForwardsPolicyAndReturnsStableMetrics() async throws {
        let processor = AudioTranscriptionProcessorSpy()
        let progress = AudioProgressRecorder()
        let useCase = TranscribeAudioFile(
            files: AudioInputFilesFake(readable: true),
            processor: processor)

        let result = try await useCase.execute(TranscribeAudioFileRequest(
            fileURL: URL(fileURLWithPath: "/meeting.wav"),
            engine: .parakeet,
            language: "es",
            vocabulary: ["Portavoz"]
        ) { event in
            await progress.append(event)
        })

        let recordedCall = await processor.lastCall
        let call = try XCTUnwrap(recordedCall)
        XCTAssertEqual(call.engine, .parakeet)
        XCTAssertEqual(call.language, "es")
        XCTAssertEqual(call.vocabulary, ["Portavoz"])
        XCTAssertEqual(result.segments.map(\.text), ["Hola desde Portavoz."])
        XCTAssertEqual(result.audioDuration, 4)
        XCTAssertEqual(result.processingTime, 2)
        XCTAssertEqual(result.speedFactor, 2)
        let progressEvents = await progress.events
        XCTAssertEqual(progressEvents, [
            .transcribing(fileName: "meeting.wav", engine: .parakeet),
        ])
    }

    func testDiarizeOwnsThresholdTimingAndOptionalAttribution() async throws {
        let processor = AudioDiarizationProcessorSpy()
        let meetingID = MeetingID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000411")!)
        let useCase = DiarizeAudioFile(
            files: AudioInputFilesFake(readable: true),
            processor: processor,
            makeMeetingID: { meetingID },
            now: { Date(timeIntervalSince1970: 10) })

        let result = try await useCase.execute(DiarizeAudioFileRequest(
            fileURL: URL(fileURLWithPath: "/meeting.wav"),
            clusteringThreshold: 0.38,
            attributeTranscript: true,
            language: "es"))

        let state = await processor.state
        XCTAssertEqual(state.thresholds, [0.38, 0.38])
        XCTAssertEqual(state.attributionLanguages, ["es"])
        XCTAssertEqual(state.attributionMeetingIDs, [meetingID])
        XCTAssertEqual(result.elapsed, 0)
        XCTAssertEqual(result.speakers.map(\.label), ["S1"])
        XCTAssertEqual(result.segments.map(\.text), ["Hola desde Portavoz."])

        _ = try await useCase.execute(DiarizeAudioFileRequest(
            fileURL: URL(fileURLWithPath: "/meeting.wav"),
            clusteringThreshold: 0.45,
            attributeTranscript: false,
            language: nil))
        let finalState = await processor.state
        XCTAssertEqual(finalState.attributionLanguages.count, 1)
    }

    func testSummarizePersistsSourceBeforeProviderEgressAndSummaryAfterward() async throws {
        let events = AudioWorkflowEventRecorder()
        let processor = AudioSummaryProcessorFake(events: events)
        let store = AnalyzedMeetingStoreFake(events: events)
        let meetingID = MeetingID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000412")!)
        let useCase = SummarizeAudioFile(
            files: AudioInputFilesFake(readable: true),
            processor: processor,
            store: store,
            makeMeetingID: { meetingID },
            now: { Date(timeIntervalSince1970: 100) })

        let result = try await useCase.execute(SummarizeAudioFileRequest(
            fileURL: URL(fileURLWithPath: "/quarterly.wav"),
            spokenLanguage: "es",
            outputLanguage: "en",
            glossary: ["Portavoz"]))

        let recordedEvents = await events.events
        XCTAssertEqual(recordedEvents, [
            "prepare", "transcribe", "diarize", "save-meeting", "summarize", "save-summary",
        ])
        XCTAssertEqual(result.meetingID, meetingID)
        XCTAssertEqual(result.draft.language, "en")
        XCTAssertEqual(result.savedVersion, 3)
        let recordedMeeting = await store.savedMeeting
        let saved = try XCTUnwrap(recordedMeeting)
        XCTAssertEqual(saved.title, "quarterly")
        XCTAssertEqual(saved.language, "es")
    }
}

private struct AudioInputFilesFake: ApplicationInputFileAccess {
    let readable: Bool
    func isReadableFile(_ url: URL) async -> Bool {
        _ = url
        return readable
    }
}

private actor AudioProgressRecorder {
    private(set) var events: [AudioAnalysisProgress] = []
    func append(_ event: AudioAnalysisProgress) { events.append(event) }
}

private actor AudioTranscriptionProcessorSpy: AudioFileTranscriptionProcessor {
    struct Call: Sendable {
        let engine: AudioAnalysisEngine
        let language: String?
        let vocabulary: [String]
    }

    private(set) var lastCall: Call?
    private(set) var callCount = 0

    func transcribe(
        fileURL: URL,
        engine: AudioAnalysisEngine,
        hints: TranscriptionHints,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> FileTranscription {
        _ = fileURL
        _ = progress
        callCount += 1
        lastCall = Call(
            engine: engine,
            language: hints.language,
            vocabulary: hints.vocabulary)
        return audioFileTranscription()
    }
}

private actor AudioDiarizationProcessorSpy: AudioFileDiarizationProcessor {
    struct State: Sendable {
        var thresholds: [Float] = []
        var attributionLanguages: [String?] = []
        var attributionMeetingIDs: [MeetingID?] = []
    }

    private var mutableState = State()
    var state: State { mutableState }

    func prepare(
        clusteringThreshold: Float,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws {
        _ = progress
        mutableState.thresholds.append(clusteringThreshold)
    }

    func diarize(
        fileURL: URL,
        clusteringThreshold: Float,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> [SpeakerTurn] {
        _ = fileURL
        _ = progress
        mutableState.thresholds.append(clusteringThreshold)
        return [SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 4)]
    }

    func transcribeForAttribution(
        fileURL: URL,
        hints: TranscriptionHints,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> FileTranscription {
        _ = fileURL
        _ = progress
        mutableState.attributionLanguages.append(hints.language)
        mutableState.attributionMeetingIDs.append(hints.meetingID)
        return audioFileTranscription(meetingID: hints.meetingID ?? MeetingID())
    }
}

private actor AudioWorkflowEventRecorder {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private actor AudioSummaryProcessorFake: AudioFileSummaryProcessor {
    let events: AudioWorkflowEventRecorder

    init(events: AudioWorkflowEventRecorder) { self.events = events }

    func prepare(progress: @escaping AudioAnalysisProgressHandler) async throws {
        _ = progress
        await events.append("prepare")
    }

    func transcribe(
        fileURL: URL,
        hints: TranscriptionHints,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> FileTranscription {
        _ = fileURL
        _ = progress
        await events.append("transcribe")
        return audioFileTranscription(meetingID: hints.meetingID ?? MeetingID())
    }

    func diarize(
        fileURL: URL,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws -> [SpeakerTurn] {
        _ = fileURL
        _ = progress
        await events.append("diarize")
        return [SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 4)]
    }

    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        await events.append("summarize")
        return SummaryDraft(
            meetingID: request.meetingID,
            recipeID: Recipe.general.id,
            language: request.targetLanguage,
            markdown: "# Summary",
            actionItems: [])
    }
}

private actor AnalyzedMeetingStoreFake: AnalyzedMeetingStore {
    let events: AudioWorkflowEventRecorder
    private(set) var savedMeeting: Meeting?

    init(events: AudioWorkflowEventRecorder) { self.events = events }

    func saveAnalyzedMeeting(
        _ meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) async throws {
        _ = speakers
        _ = segments
        savedMeeting = meeting
        await events.append("save-meeting")
    }

    func saveAnalyzedSummary(_ draft: SummaryDraft) async throws -> Int {
        _ = draft
        await events.append("save-summary")
        return 3
    }
}

private func audioFileTranscription(
    meetingID: MeetingID = MeetingID()
) -> FileTranscription {
    FileTranscription(
        text: "Hola desde Portavoz.",
        segments: [TranscriptSegment(
            meetingID: meetingID,
            channel: .system,
            text: "Hola desde Portavoz.",
            language: "es",
            startTime: 0,
            endTime: 4,
            isFinal: true)],
        audioDuration: 4,
        processingTime: 2)
}

private extension XCTestCase {
    func assertThrows<T: Error & Equatable>(
        _ expected: T,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch let error as T {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
