import ApplicationKit
import DiarizationKit
import Foundation
import GRDB
import PortavozCore
import TranscriptionKit
import XCTest

@testable import StorageKit

final class RefineMeetingUseCaseTests: XCTestCase {
    func testDraftPreservesOrderLanguageFiltersAttributionComparisonAndRelease() async throws {
        let fixture = RefineFixture()
        let dependencies = RefineDependencies(
            preferences: .init(
                transcriptLanguage: .fixed(.spanish),
                vocabulary: ["Portavoz"]),
            audio: fixture.audio,
            systemTranscription: fixture.systemTranscription,
            microphoneTranscription: fixture.microphoneTranscription,
            turns: [SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 5)])

        let draft = try await fixture.useCase(dependencies)(
            fixture.request(dependencies))

        let state = await dependencies.state()
        XCTAssertEqual(state.progress, [
            .preparingModels,
            .downloadingWhisper(size: "1.6 GB", percent: 42),
            .transcribingParticipants,
            .transcribingMicrophone,
            .identifyingSpeakers,
        ])
        XCTAssertEqual(state.events, [
            "resolve-audio", "prepare", "preferences", "transcribe-system",
            "transcribe-microphone", "diarize", "release",
        ])
        XCTAssertEqual(state.languageHints, ["es", "es"])
        XCTAssertEqual(state.vocabularies, [["Portavoz"], ["Portavoz"]])
        XCTAssertEqual(draft.sourceTranscriptRevision, fixture.meeting.transcriptRevision)
        XCTAssertEqual(draft.language, "es")
        XCTAssertEqual(draft.segments.map(\.text), [
            "Revisamos el presupuesto trimestral y aprobamos el lanzamiento.",
            "Yo prepararé el despliegue mañana por la mañana.",
        ])
        XCTAssertEqual(draft.speakers.map(\.label), ["Me", "S1"])
        XCTAssertEqual(draft.oldSegmentCount, 1)
        XCTAssertEqual(draft.oldSpeakerCount, 1)
        XCTAssertEqual(draft.oldSpeechSeconds, 8)
        XCTAssertEqual(draft.meetingSeconds, 12)
        let run = try XCTUnwrap(draft.generationRun)
        XCTAssertEqual(run.id, fixture.generationRunID)
        XCTAssertEqual(run.kind, .transcript)
        XCTAssertEqual(run.providerID, "whisperkit/coreml")
        XCTAssertEqual(run.modelID, "whisper-large-v3-test")
        XCTAssertEqual(run.modelRevision, "test-revision")
        XCTAssertEqual(run.inputFingerprint.count, 64)
        XCTAssertEqual(
            run.configJSON,
            #"{"channels":["system","microphone"],"languageMode":"fixed","operation":"transcribe","sourceTranscriptRevision":4,"vocabularyCount":1,"workflow":"meeting-refine"}"#)
        XCTAssertEqual(run.outputLanguage, "es")
        XCTAssertEqual(run.outcome, .succeeded)
        XCTAssertEqual(
            run.metricsJSON,
            "{\"outputUTF8Bytes\":\(draft.segments.reduce(0) { $0 + $1.text.utf8.count }),"
                + "\"segmentCount\":2,\"speechMilliseconds\":8000}")
        XCTAssertFalse(run.configJSON.contains("Portavoz"))
        XCTAssertFalse(run.metricsJSON?.contains("presupuesto") == true)
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testAutomaticMixedMeetingKeepsWhisperAutomaticAndAggregateLanguageUnknown() async throws {
        let fixture = RefineFixture()
        let mixedSystem = FileTranscription(
            text: "Hola. We agreed.",
            segments: [
                fixture.segment(
                    text: "Esta intervención permanece en español.",
                    language: "es",
                    channel: .system,
                    start: 0,
                    end: 4),
                fixture.segment(
                    text: "This contribution remains in English.",
                    language: "en",
                    channel: .system,
                    start: 4,
                    end: 8),
            ],
            audioDuration: 8,
            processingTime: 1)
        let dependencies = RefineDependencies(
            audio: RefineMeetingAudio(system: fixture.audio.system, microphone: nil),
            systemTranscription: mixedSystem,
            microphoneTranscription: fixture.microphoneTranscription,
            turns: [])

        let request = RefineMeetingRequest(
            detail: fixture.detail(segments: mixedSystem.segments)) { progress in
                await dependencies.record(progress)
            }
        let draft = try await fixture.useCase(dependencies)(request)

        let state = await dependencies.state()
        XCTAssertEqual(state.languageHints, [nil])
        XCTAssertNil(draft.language)
        XCTAssertEqual(draft.segments.map(\.language), ["es", "en"])
        XCTAssertNil(draft.generationRun?.outputLanguage)
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testExplicitRecoveryLanguageOverridesMixedEvidence() async throws {
        let fixture = RefineFixture()
        let mixedDetail = fixture.detail(
            segments: [
                fixture.segment(
                    text: "Esta parte está en español.", language: "es",
                    channel: .system, start: 0, end: 4),
                fixture.segment(
                    text: "This part stays in English.", language: "en",
                    channel: .system, start: 4, end: 8),
            ])
        let dependencies = RefineDependencies(
            audio: RefineMeetingAudio(system: fixture.audio.system, microphone: nil),
            systemTranscription: fixture.systemTranscription,
            microphoneTranscription: fixture.microphoneTranscription,
            turns: [])
        let request = RefineMeetingRequest(
            detail: mixedDetail,
            languagePolicy: .fixed(.english)) { progress in
                await dependencies.record(progress)
            }

        _ = try await fixture.useCase(dependencies)(request)

        let state = await dependencies.state()
        XCTAssertEqual(state.languageHints, ["en"])
    }

    func testSilentChannelsProduceAnEmptyReviewDraftWithoutHallucinations() async throws {
        let fixture = RefineFixture()
        let dependencies = RefineDependencies(
            audio: RefineMeetingAudio(
                system: RefineMeetingAudioChannel(
                    fileURL: fixture.systemURL,
                    isSilent: true,
                    contentFingerprint: "silent-system-sha"),
                microphone: RefineMeetingAudioChannel(
                    fileURL: fixture.microphoneURL,
                    isSilent: true,
                    contentFingerprint: "silent-microphone-sha")),
            systemTranscription: fixture.systemTranscription,
            microphoneTranscription: fixture.microphoneTranscription,
            turns: [])

        let draft = try await fixture.useCase(dependencies)(fixture.request(dependencies))

        let state = await dependencies.state()
        XCTAssertTrue(draft.segments.isEmpty)
        XCTAssertTrue(draft.speakers.isEmpty)
        XCTAssertNil(draft.language)
        XCTAssertNil(draft.generationRun)
        XCTAssertFalse(state.events.contains { $0.hasPrefix("transcribe-") })
        XCTAssertFalse(state.events.contains("diarize"))
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testMissingAudioFailsBeforeModelsAndDoesNotScheduleRelease() async {
        let fixture = RefineFixture()
        let noDirectory = fixture.detail(meeting: Meeting(
            id: fixture.meetingID,
            title: "No retained audio",
            startedAt: fixture.startedAt,
            endedAt: fixture.startedAt.addingTimeInterval(12),
            language: "es",
            audioDirectory: nil,
            transcriptRevision: 4))
        let noFiles = RefineDependencies(
            audio: RefineMeetingAudio(system: nil, microphone: nil),
            systemTranscription: fixture.systemTranscription,
            microphoneTranscription: fixture.microphoneTranscription,
            turns: [])

        await assertThrows(RefineMeetingError.audioNotRetained) {
            _ = try await fixture.useCase(noFiles)(
                RefineMeetingRequest(detail: noDirectory))
        }
        await assertThrows(RefineMeetingError.audioUnavailable) {
            _ = try await fixture.useCase(noFiles)(fixture.request(noFiles))
        }

        let state = await noFiles.state()
        XCTAssertEqual(state.events, ["resolve-audio"])
        XCTAssertEqual(state.releaseCount, 0)
    }

    func testRequiredFailuresScheduleReleaseAndNeverProduceDraft() async {
        for failure in [RefineFailure.preparation, .transcription] {
            let fixture = RefineFixture()
            let dependencies = RefineDependencies(
                audio: fixture.audio,
                systemTranscription: fixture.systemTranscription,
                microphoneTranscription: fixture.microphoneTranscription,
                turns: [],
                failures: [failure])

            await assertThrowsDependencyError {
                _ = try await fixture.useCase(dependencies)(fixture.request(dependencies))
            }

            let state = await dependencies.state()
            XCTAssertEqual(state.releaseCount, 1, "failure: \(failure)")
            if failure == .preparation {
                XCTAssertTrue(state.standaloneRuns.isEmpty)
            } else {
                XCTAssertEqual(state.standaloneRuns.map(\.outcome), [.failed])
                XCTAssertTrue(state.standaloneRuns.allSatisfy { $0.metricsJSON == nil })
            }
        }
    }

    func testDiarizationFailureDegradesToHonestUnattributedSystemTranscript() async throws {
        let fixture = RefineFixture()
        let dependencies = RefineDependencies(
            audio: RefineMeetingAudio(system: fixture.audio.system, microphone: nil),
            systemTranscription: fixture.systemTranscription,
            microphoneTranscription: fixture.microphoneTranscription,
            turns: [],
            failures: [.diarization])

        let draft = try await fixture.useCase(dependencies)(fixture.request(dependencies))

        XCTAssertTrue(draft.speakers.isEmpty)
        XCTAssertTrue(draft.segments.allSatisfy { $0.speakerID == nil })
        let state = await dependencies.state()
        XCTAssertEqual(state.releaseCount, 1)
        XCTAssertEqual(draft.generationRun?.outcome, .succeeded)
        XCTAssertTrue(state.standaloneRuns.isEmpty)
    }

    func testCancellationPropagatesAndSchedulesRelease() async throws {
        let fixture = RefineFixture()
        let dependencies = RefineDependencies(
            audio: fixture.audio,
            systemTranscription: fixture.systemTranscription,
            microphoneTranscription: fixture.microphoneTranscription,
            turns: [],
            failures: [.suspendTranscription])
        let task = Task {
            try await fixture.useCase(dependencies)(fixture.request(dependencies))
        }
        await dependencies.waitForTranscriptionStart()

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a canceled refine must not publish a draft")
        } catch is CancellationError {
            // Expected.
        }
        let state = await dependencies.state()
        XCTAssertEqual(state.releaseCount, 1)
        XCTAssertEqual(state.standaloneRuns.map(\.outcome), [.cancelled])
        XCTAssertNil(state.standaloneRuns.first?.metricsJSON)
    }

    func testApplyUsesRevisionFenceAndSkipsUnavailableCompanion() async throws {
        let fixture = RefineFixture()
        let dependencies = RefineDependencies(
            audio: fixture.audio,
            systemTranscription: fixture.systemTranscription,
            microphoneTranscription: fixture.microphoneTranscription,
            turns: [],
            companionAvailable: false)
        let draft = fixture.draft()
        let useCase = ApplyRefinedMeeting(store: dependencies, companion: dependencies)

        let result = try await useCase(fixture.applyRequest(draft, dependencies))

        let state = await dependencies.state()
        XCTAssertEqual(result.transcriptRevision, 5)
        XCTAssertEqual(result.companion, .skipped)
        XCTAssertEqual(state.applied?.expectedTranscriptRevision, 4)
        XCTAssertEqual(state.applied?.language, "es")
        XCTAssertEqual(state.applied?.segments.map(\.text), draft.segments.map(\.text))
        XCTAssertEqual(state.applied?.generationRun?.id, fixture.generationRunID)
        XCTAssertEqual(state.applyProgress, [.applyingTranscript])
        XCTAssertEqual(state.events, ["apply"])
    }

    func testCompletedCompanionRefreshReplacesSnapshotIncludingEmptyResult() async throws {
        let fixture = RefineFixture()
        for cards in [fixture.companionCards, []] {
            let dependencies = RefineDependencies(
                audio: fixture.audio,
                systemTranscription: fixture.systemTranscription,
                microphoneTranscription: fixture.microphoneTranscription,
                turns: [],
                companionAvailable: true,
                companionRefresh: RefineMeetingCompanionRefresh(
                    cards: cards,
                    completed: true))
            let useCase = ApplyRefinedMeeting(store: dependencies, companion: dependencies)

            let result = try await useCase(
                fixture.applyRequest(fixture.draft(), dependencies))

            let state = await dependencies.state()
            XCTAssertEqual(result.companion, .replaced(count: cards.count))
            XCTAssertEqual(state.savedCompanionCards, cards)
            XCTAssertEqual(state.applyProgress, [
                .applyingTranscript, .refreshingCompanion,
            ])
        }
    }

    func testIncompleteCompanionRefreshPreservesPreviousSnapshot() async throws {
        let fixture = RefineFixture()
        let dependencies = RefineDependencies(
            audio: fixture.audio,
            systemTranscription: fixture.systemTranscription,
            microphoneTranscription: fixture.microphoneTranscription,
            turns: [],
            companionAvailable: true,
            companionRefresh: RefineMeetingCompanionRefresh(
                cards: fixture.companionCards,
                completed: false))

        let result = try await ApplyRefinedMeeting(
            store: dependencies,
            companion: dependencies)(fixture.applyRequest(fixture.draft(), dependencies))

        let state = await dependencies.state()
        XCTAssertEqual(result.companion, .preserved)
        XCTAssertNil(state.savedCompanionCards)
    }

    func testCompanionPersistenceFailureDoesNotTurnCommittedTranscriptIntoFailure() async throws {
        let fixture = RefineFixture()
        let dependencies = RefineDependencies(
            audio: fixture.audio,
            systemTranscription: fixture.systemTranscription,
            microphoneTranscription: fixture.microphoneTranscription,
            turns: [],
            companionAvailable: true,
            companionRefresh: RefineMeetingCompanionRefresh(
                cards: fixture.companionCards,
                completed: true),
            failures: [.companionPersistence])

        let result = try await ApplyRefinedMeeting(
            store: dependencies,
            companion: dependencies)(fixture.applyRequest(fixture.draft(), dependencies))

        let state = await dependencies.state()
        XCTAssertEqual(result.companion, .persistenceFailed)
        XCTAssertNotNil(state.applied)
    }

    func testEmptyDraftCannotReachStorage() async {
        let fixture = RefineFixture()
        let dependencies = RefineDependencies(
            audio: fixture.audio,
            systemTranscription: fixture.systemTranscription,
            microphoneTranscription: fixture.microphoneTranscription,
            turns: [])
        let empty = RefineDraft(
            sourceTranscriptRevision: 4,
            language: nil,
            speakers: [],
            segments: [],
            oldSegmentCount: 1,
            oldSpeakerCount: 1,
            oldSpeechSeconds: 8,
            meetingSeconds: 12)

        await assertThrows(ApplyRefinedMeetingError.emptyDraft) {
            _ = try await ApplyRefinedMeeting(
                store: dependencies,
                companion: dependencies)(fixture.applyRequest(empty, dependencies))
        }

        let state = await dependencies.state()
        XCTAssertNil(state.applied)
    }

    func testRealStoreApplyIsAtomicRevisionedAndPreservesImmutableSummary() async throws {
        let fixture = RefineFixture()
        let store = try MeetingStore.inMemory()
        try await fixture.seed(store)
        let companion = RefineDependencies(
            audio: fixture.audio,
            systemTranscription: fixture.systemTranscription,
            microphoneTranscription: fixture.microphoneTranscription,
            turns: [],
            companionAvailable: false)

        let result = try await ApplyRefinedMeeting(store: store, companion: companion)(
            ApplyRefinedMeetingRequest(meetingID: fixture.meetingID, draft: fixture.draft()))

        let storedDetail = try await store.detail(fixture.meetingID)
        let detail = try XCTUnwrap(storedDetail)
        XCTAssertEqual(result.transcriptRevision, 5)
        XCTAssertEqual(detail.meeting.transcriptRevision, 5)
        XCTAssertEqual(detail.meeting.language, "es")
        XCTAssertEqual(detail.segments.map(\.text), fixture.draft().segments.map(\.text))
        XCTAssertEqual(detail.speakers.map(\.label), ["S1"])
        XCTAssertEqual(detail.summaries.count, 1)
        let runs = try await store.generationRuns(for: fixture.meetingID)
        XCTAssertEqual(runs, [try XCTUnwrap(fixture.draft().generationRun)])
        let linkedRunIDs = try await store.database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT generationRunID FROM segment "
                    + "WHERE meetingID = ? AND deletedAt IS NULL",
                arguments: [fixture.meetingID.rawValue.uuidString])
        }
        XCTAssertEqual(linkedRunIDs, [fixture.generationRunID.rawValue.uuidString])
        var editedSegment = try XCTUnwrap(detail.segments.first)
        editedSegment.text = "Edited accepted transcript keeps its origin."
        try await store.save([editedSegment])
        let editedSegmentID = editedSegment.id.uuidString
        let retainedRunID = try await store.database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT generationRunID FROM segment WHERE id = ?",
                arguments: [editedSegmentID])
        }
        XCTAssertEqual(retainedRunID, fixture.generationRunID.rawValue.uuidString)
        let summary = try await store.summary(fixture.meetingID)
        XCTAssertEqual(summary?.draft.markdown, "# Existing")
    }

    func testInvalidRefineProvenanceCannotMutateTheAcceptedAggregate() async throws {
        let fixture = RefineFixture()
        let store = try MeetingStore.inMemory()
        try await fixture.seed(store)
        let draft = fixture.draft()
        let timestamp = fixture.startedAt.addingTimeInterval(20)
        let invalidRuns = [
            GenerationRun(
                meetingID: fixture.meetingID,
                kind: .summary,
                providerID: "whisperkit/coreml",
                modelID: "whisper-large-v3-test",
                inputFingerprint: String(repeating: "a", count: 64),
                configJSON: fixture.successfulGenerationRun().configJSON,
                outputLanguage: "es",
                startedAt: timestamp,
                finishedAt: timestamp,
                outcome: .succeeded),
            GenerationRun(
                meetingID: fixture.meetingID,
                kind: .transcript,
                providerID: "whisperkit/coreml",
                modelID: "whisper-large-v3-test",
                inputFingerprint: String(repeating: "b", count: 64),
                configJSON: #"{"sourceTranscriptRevision":3,"workflow":"meeting-refine"}"#,
                outputLanguage: "es",
                startedAt: timestamp,
                finishedAt: timestamp,
                outcome: .succeeded),
            GenerationRun(
                meetingID: fixture.meetingID,
                kind: .transcript,
                providerID: "whisperkit/coreml",
                modelID: "whisper-large-v3-test",
                inputFingerprint: String(repeating: "c", count: 64),
                configJSON: fixture.successfulGenerationRun().configJSON,
                outputLanguage: "en",
                startedAt: timestamp,
                finishedAt: timestamp,
                outcome: .succeeded),
        ]

        for run in invalidRuns {
            do {
                try await store.applyRefinedCast(
                    for: fixture.meetingID,
                    expectedTranscriptRevision: 4,
                    language: "es",
                    speakers: draft.speakers,
                    segments: draft.segments,
                    generationRun: run)
                XCTFail("invalid transcript provenance must not be accepted")
            } catch let error as StorageError {
                guard case .invalidGenerationRun = error else {
                    return XCTFail("unexpected storage error: \(error)")
                }
            }
        }

        let storedDetail = try await store.detail(fixture.meetingID)
        let detail = try XCTUnwrap(storedDetail)
        XCTAssertEqual(detail.meeting.transcriptRevision, 4)
        XCTAssertEqual(detail.meeting.language, "en")
        XCTAssertEqual(detail.segments.map(\.text), ["Original transcript remains intact."])
        let runs = try await store.generationRuns(for: fixture.meetingID)
        XCTAssertTrue(runs.isEmpty)
    }

    func testStaleDraftRejectsWholeApplyAndPreservesCurrentAggregate() async throws {
        let fixture = RefineFixture()
        let store = try MeetingStore.inMemory()
        try await fixture.seed(store)
        var meeting = fixture.meeting
        meeting.transcriptRevision = 5
        try await store.save(meeting)
        let draft = fixture.draft()

        do {
            try await store.applyRefinedCast(
                for: fixture.meetingID,
                expectedTranscriptRevision: 4,
                language: "es",
                speakers: draft.speakers,
                segments: draft.segments,
                generationRun: draft.generationRun)
            XCTFail("a stale draft must not replace a newer transcript")
        } catch let error as StorageError {
            guard case .staleRefineDraft(_, 4, 5) = error else {
                return XCTFail("unexpected storage error: \(error)")
            }
        }

        let storedDetail = try await store.detail(fixture.meetingID)
        let detail = try XCTUnwrap(storedDetail)
        XCTAssertEqual(detail.meeting.transcriptRevision, 5)
        XCTAssertEqual(detail.meeting.language, "en")
        XCTAssertEqual(detail.segments.map(\.text), ["Original transcript remains intact."])
        XCTAssertEqual(detail.summaries.count, 1)
        let runs = try await store.generationRuns(for: fixture.meetingID)
        XCTAssertTrue(runs.isEmpty)
    }

    func testRefinedCastTransactionRollsBackMetadataAndChildrenOnInsertFailure() async throws {
        let fixture = RefineFixture()
        let store = try MeetingStore.inMemory()
        try await fixture.seed(store)
        let draft = fixture.draft()
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_refined_segment
                BEFORE INSERT ON segment
                WHEN NEW.text LIKE 'Refined%'
                BEGIN
                    SELECT RAISE(ABORT, 'injected refine child failure');
                END
                """)
        }

        do {
            try await store.applyRefinedCast(
                for: fixture.meetingID,
                expectedTranscriptRevision: 4,
                language: "es",
                speakers: draft.speakers,
                segments: draft.segments,
                generationRun: draft.generationRun)
            XCTFail("child failure must reject the entire refined aggregate")
        } catch {
            let storedDetail = try await store.detail(fixture.meetingID)
            let detail = try XCTUnwrap(storedDetail)
            XCTAssertEqual(detail.meeting.transcriptRevision, 4)
            XCTAssertEqual(detail.meeting.language, "en")
            XCTAssertEqual(detail.speakers.map(\.label), ["Original"])
            XCTAssertEqual(detail.segments.map(\.text), ["Original transcript remains intact."])
            XCTAssertEqual(detail.summaries.count, 1)
            let runs = try await store.generationRuns(for: fixture.meetingID)
            XCTAssertTrue(runs.isEmpty)
        }
    }
}

private struct RefineFixture: Sendable {
    let meetingID = MeetingID(
        rawValue: UUID(uuidString: "B2000000-0000-0000-0000-000000000001")!)
    let generationRunID = GenerationRunID(
        rawValue: UUID(uuidString: "B2000000-0000-0000-0000-000000000002")!)
    let startedAt = Date(timeIntervalSince1970: 1_750_100_000)
    let systemURL = URL(fileURLWithPath: "/scratch/Audio/refine/system.caf")
    let microphoneURL = URL(fileURLWithPath: "/scratch/Audio/refine/microphone.caf")

    var meeting: Meeting {
        Meeting(
            id: meetingID,
            title: "Refine fixture",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(12),
            language: "en",
            audioDirectory: "Audio/refine",
            transcriptRevision: 4)
    }

    var originalSpeaker: Speaker {
        Speaker(meetingID: meetingID, label: "Original")
    }

    var originalSegment: TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID,
            speakerID: originalSpeaker.id,
            channel: .system,
            text: "Original transcript remains intact.",
            language: "en",
            startTime: 0,
            endTime: 8,
            isFinal: true)
    }

    var audio: RefineMeetingAudio {
        RefineMeetingAudio(
            system: RefineMeetingAudioChannel(
                fileURL: systemURL,
                isSilent: false,
                contentFingerprint: "system-audio-sha"),
            microphone: RefineMeetingAudioChannel(
                fileURL: microphoneURL,
                isSilent: false,
                contentFingerprint: "microphone-audio-sha"))
    }

    var systemTranscription: FileTranscription {
        FileTranscription(
            text: "Revisamos el presupuesto.",
            segments: [
                segment(
                    text: "Revisamos el presupuesto trimestral y aprobamos el lanzamiento.",
                    language: "es",
                    channel: .system,
                    start: 0,
                    end: 5),
            ],
            audioDuration: 12,
            processingTime: 1)
    }

    var microphoneTranscription: FileTranscription {
        FileTranscription(
            text: "Eco. Yo prepararé.",
            segments: [
                segment(
                    text: ".", language: "es", channel: .microphone,
                    start: 0, end: 0.5, confidence: 0.1),
                segment(
                    text: "Revisamos el presupuesto trimestral y aprobamos el lanzamiento.",
                    language: "es", channel: .microphone,
                    start: 0, end: 5),
                segment(
                    text: "Yo prepararé el despliegue mañana por la mañana.",
                    language: "es", channel: .microphone,
                    start: 6, end: 9),
            ],
            audioDuration: 12,
            processingTime: 1)
    }

    var companionCards: [CompanionCard] {
        [
            CompanionCard(
                question: "¿Cuándo sale?",
                answer: "Mañana.",
                kind: .context,
                source: "on-device",
                askedAt: 4),
        ]
    }

    func segment(
        text: String,
        language: String,
        channel: AudioChannel,
        start: TimeInterval,
        end: TimeInterval,
        confidence: Double? = 0.95
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID,
            channel: channel,
            text: text,
            language: language,
            startTime: start,
            endTime: end,
            confidence: confidence,
            isFinal: true)
    }

    func detail(
        meeting: Meeting? = nil,
        segments: [TranscriptSegment]? = nil
    ) -> MeetingDetail {
        MeetingDetail(
            meeting: meeting ?? self.meeting,
            speakers: [originalSpeaker],
            segments: segments ?? [originalSegment],
            summaries: [])
    }

    func request(_ dependencies: RefineDependencies) -> RefineMeetingRequest {
        RefineMeetingRequest(detail: detail()) { progress in
            await dependencies.record(progress)
        }
    }

    func useCase(_ dependencies: RefineDependencies) -> RefineMeeting {
        RefineMeeting(
            audioFiles: dependencies,
            preferences: dependencies,
            processor: dependencies,
            store: dependencies,
            makeGenerationRunID: { generationRunID },
            now: { startedAt.addingTimeInterval(20) })
    }

    func draft() -> RefineDraft {
        let speaker = Speaker(meetingID: meetingID, label: "S1")
        return RefineDraft(
            sourceTranscriptRevision: 4,
            language: "es",
            speakers: [speaker],
            segments: [
                TranscriptSegment(
                    meetingID: meetingID,
                    speakerID: speaker.id,
                    channel: .system,
                    text: "Refined transcript is accepted atomically.",
                    language: "es",
                    startTime: 0,
                    endTime: 9,
                    isFinal: true),
            ],
            oldSegmentCount: 1,
            oldSpeakerCount: 1,
            oldSpeechSeconds: 8,
            meetingSeconds: 12,
            generationRun: successfulGenerationRun())
    }

    func successfulGenerationRun() -> GenerationRun {
        let timestamp = startedAt.addingTimeInterval(20)
        return GenerationRun(
            id: generationRunID,
            meetingID: meetingID,
            kind: .transcript,
            providerID: "whisperkit/coreml",
            modelID: "whisper-large-v3-test",
            modelRevision: "test-revision",
            inputFingerprint: String(repeating: "a", count: 64),
            configJSON: #"{"channels":["system"],"languageMode":"automatic","operation":"transcribe","sourceTranscriptRevision":4,"vocabularyCount":0,"workflow":"meeting-refine"}"#,
            outputLanguage: "es",
            startedAt: timestamp,
            finishedAt: timestamp,
            outcome: .succeeded,
            metricsJSON: #"{"outputUTF8Bytes":42,"segmentCount":1,"speechMilliseconds":9000}"#)
    }

    func applyRequest(
        _ draft: RefineDraft,
        _ dependencies: RefineDependencies
    ) -> ApplyRefinedMeetingRequest {
        ApplyRefinedMeetingRequest(meetingID: meetingID, draft: draft) { progress in
            await dependencies.record(progress)
        }
    }

    func seed(_ store: MeetingStore) async throws {
        try await store.save(meeting)
        try await store.save([originalSpeaker])
        try await store.save([originalSegment])
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meetingID,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "# Existing",
            actionItems: []))
    }
}

private enum RefineFailure: Hashable, Sendable {
    case preparation
    case transcription
    case suspendTranscription
    case diarization
    case apply
    case companionPersistence
}

private struct RefineDependencyError: Error {}

private struct AppliedRefine: Sendable {
    let meetingID: MeetingID
    let expectedTranscriptRevision: Int
    let language: String?
    let speakers: [Speaker]
    let segments: [TranscriptSegment]
    let generationRun: GenerationRun?
}

private struct RefineDependencyState: Sendable {
    let events: [String]
    let progress: [RefineMeetingProgress]
    let applyProgress: [ApplyRefinedMeetingProgress]
    let languageHints: [String?]
    let vocabularies: [[String]]
    let releaseCount: Int
    let applied: AppliedRefine?
    let savedCompanionCards: [CompanionCard]?
    let standaloneRuns: [GenerationRun]
}

private actor RefineDependencies:
    RefineMeetingAudioFiles,
    RefineMeetingPreferences,
    RefineMeetingProcessor,
    RefineMeetingStore,
    RefineMeetingCompanion
{
    private let preferences: RefineMeetingPreferencesSnapshot
    private let audio: RefineMeetingAudio
    private let systemTranscription: FileTranscription
    private let microphoneTranscription: FileTranscription
    private let turns: [SpeakerTurn]
    private let companionAvailable: Bool
    private let companionRefresh: RefineMeetingCompanionRefresh
    private let failures: Set<RefineFailure>
    private var events: [String] = []
    private var progressEvents: [RefineMeetingProgress] = []
    private var applyProgressEvents: [ApplyRefinedMeetingProgress] = []
    private var languageHints: [String?] = []
    private var vocabularies: [[String]] = []
    private var releaseCount = 0
    private var applied: AppliedRefine?
    private var savedCompanionCards: [CompanionCard]?
    private var standaloneRuns: [GenerationRun] = []
    private var transcriptionStarted = false
    private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        preferences: RefineMeetingPreferencesSnapshot = .init(
            transcriptLanguage: .automatic,
            vocabulary: []),
        audio: RefineMeetingAudio,
        systemTranscription: FileTranscription,
        microphoneTranscription: FileTranscription,
        turns: [SpeakerTurn],
        companionAvailable: Bool = false,
        companionRefresh: RefineMeetingCompanionRefresh = .init(
            cards: [],
            completed: true),
        failures: Set<RefineFailure> = []
    ) {
        self.preferences = preferences
        self.audio = audio
        self.systemTranscription = systemTranscription
        self.microphoneTranscription = microphoneTranscription
        self.turns = turns
        self.companionAvailable = companionAvailable
        self.companionRefresh = companionRefresh
        self.failures = failures
    }

    func record(_ progress: RefineMeetingProgress) {
        progressEvents.append(progress)
    }

    func record(_ progress: ApplyRefinedMeetingProgress) {
        applyProgressEvents.append(progress)
    }

    func resolveRefineAudio(
        _ relativeDirectory: String,
        meetingID: MeetingID
    ) -> RefineMeetingAudio {
        events.append("resolve-audio")
        return audio
    }

    func refineMeetingPreferences() -> RefineMeetingPreferencesSnapshot {
        events.append("preferences")
        return preferences
    }

    func prepare(progress: @escaping RefineMeetingProgressHandler) async throws {
        events.append("prepare")
        if failures.contains(.preparation) { throw RefineDependencyError() }
        await progress(.downloadingWhisper(size: "1.6 GB", percent: 42))
    }

    func transcriptionProvider() -> RefineMeetingTranscriptionProvider {
        RefineMeetingTranscriptionProvider(
            providerID: "whisperkit/coreml",
            modelID: "whisper-large-v3-test",
            modelRevision: "test-revision")
    }

    func transcribe(
        fileURL: URL,
        hints: TranscriptionHints,
        channel: AudioChannel
    ) async throws -> FileTranscription {
        events.append("transcribe-\(channel.rawValue)")
        languageHints.append(hints.language)
        vocabularies.append(hints.vocabulary)
        transcriptionStarted = true
        let waiters = transcriptionWaiters
        transcriptionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if failures.contains(.transcription) { throw RefineDependencyError() }
        if failures.contains(.suspendTranscription) {
            try await Task.sleep(for: .seconds(60))
        }
        return channel == .system ? systemTranscription : microphoneTranscription
    }

    func diarize(fileURL: URL) throws -> [SpeakerTurn] {
        events.append("diarize")
        if failures.contains(.diarization) { throw RefineDependencyError() }
        return turns
    }

    func scheduleIdleRelease() {
        events.append("release")
        releaseCount += 1
    }

    func installRefinedCast(
        meetingID: MeetingID,
        expectedTranscriptRevision: Int,
        language: String?,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        generationRun: GenerationRun?
    ) throws {
        events.append("apply")
        if failures.contains(.apply) { throw RefineDependencyError() }
        applied = AppliedRefine(
            meetingID: meetingID,
            expectedTranscriptRevision: expectedTranscriptRevision,
            language: language,
            speakers: speakers,
            segments: segments,
            generationRun: generationRun)
    }

    func saveRefineGenerationRun(_ run: GenerationRun) {
        events.append("save-generation-run")
        standaloneRuns.append(run)
    }

    func replaceRefinedCompanionCards(
        _ cards: [CompanionCard],
        for meetingID: MeetingID
    ) throws {
        events.append("save-companion")
        if failures.contains(.companionPersistence) { throw RefineDependencyError() }
        savedCompanionCards = cards
    }

    func isRefreshAvailable() -> Bool { companionAvailable }

    func refresh(
        segments: [TranscriptSegment],
        meetingID: MeetingID
    ) -> RefineMeetingCompanionRefresh {
        events.append("refresh-companion")
        return companionRefresh
    }

    func waitForTranscriptionStart() async {
        if transcriptionStarted { return }
        await withCheckedContinuation { transcriptionWaiters.append($0) }
    }

    func state() -> RefineDependencyState {
        RefineDependencyState(
            events: events,
            progress: progressEvents,
            applyProgress: applyProgressEvents,
            languageHints: languageHints,
            vocabularies: vocabularies,
            releaseCount: releaseCount,
            applied: applied,
            savedCompanionCards: savedCompanionCards,
            standaloneRuns: standaloneRuns)
    }
}

private func assertThrows<T: Error & Equatable>(
    _ expected: T,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as T {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

private func assertThrowsDependencyError(
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected dependency error", file: file, line: line)
    } catch is RefineDependencyError {
        // Expected.
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}
