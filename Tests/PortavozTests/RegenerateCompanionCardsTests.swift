import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore
import XCTest

final class RegenerateCompanionCardsTests: XCTestCase {
    func testCompletedPassAtomicallyReplacesTheSnapshot() async {
        let fixture = Fixture()
        let artifact = fixture.artifact()
        let dependencies = Dependencies(result: .pass(CompanionRegenerationPass(
            artifacts: [artifact],
            completed: true)))

        let result = await RegenerateCompanionCards(
            store: dependencies,
            provider: dependencies).execute(fixture.request)

        XCTAssertEqual(result, .replaced(count: 1))
        let state = await dependencies.state()
        XCTAssertEqual(state.replacedArtifacts, [artifact])
        XCTAssertTrue(state.savedRuns.isEmpty)
    }

    func testCompletedEmptyPassRemovesQuestionsNoLongerPresent() async {
        let fixture = Fixture()
        let dependencies = Dependencies(result: .pass(CompanionRegenerationPass(
            artifacts: [],
            completed: true)))

        let result = await RegenerateCompanionCards(
            store: dependencies,
            provider: dependencies).execute(fixture.request)

        XCTAssertEqual(result, .replaced(count: 0))
        let state = await dependencies.state()
        XCTAssertEqual(state.replacedArtifacts, [])
    }

    func testIncompletePassRecordsTerminalRunsAndPreservesCards() async {
        let fixture = Fixture()
        let terminal = fixture.run(outcome: .failed)
        let dependencies = Dependencies(result: .pass(CompanionRegenerationPass(
            artifacts: [],
            terminalRuns: [terminal],
            completed: false)))

        let result = await RegenerateCompanionCards(
            store: dependencies,
            provider: dependencies).execute(fixture.request)

        XCTAssertEqual(result, .preserved)
        let state = await dependencies.state()
        XCTAssertEqual(state.savedRuns, [terminal])
        XCTAssertNil(state.replacedArtifacts)
        XCTAssertEqual(state.savedSourceRevision, fixture.material.baseTranscriptRevision)
    }

    func testTerminalRunReceiptFailureStillPreservesCards() async {
        let fixture = Fixture()
        let dependencies = Dependencies(
            result: .pass(CompanionRegenerationPass(
                artifacts: [],
                terminalRuns: [fixture.run(outcome: .failed)],
                completed: false)),
            failsRunSave: true)

        let result = await RegenerateCompanionCards(
            store: dependencies,
            provider: dependencies).execute(fixture.request)

        XCTAssertEqual(result, .preserved)
        let state = await dependencies.state()
        XCTAssertTrue(state.savedRuns.isEmpty)
        XCTAssertNil(state.replacedArtifacts)
    }

    func testContradictoryCompletedPassWithTerminalRunPreservesCards() async {
        let fixture = Fixture()
        let terminal = fixture.run(outcome: .failed)
        let dependencies = Dependencies(result: .pass(CompanionRegenerationPass(
            artifacts: [fixture.artifact()],
            terminalRuns: [terminal],
            completed: true)))

        let result = await RegenerateCompanionCards(
            store: dependencies,
            provider: dependencies).execute(fixture.request)

        XCTAssertEqual(result, .preserved)
        let state = await dependencies.state()
        XCTAssertEqual(state.savedRuns, [terminal])
        XCTAssertNil(state.replacedArtifacts)
    }

    func testUnavailableProviderDoesNotReachPersistence() async {
        let fixture = Fixture()
        let dependencies = Dependencies(result: .unavailable(.requiresMacOS26))

        let result = await RegenerateCompanionCards(
            store: dependencies,
            provider: dependencies).execute(fixture.request)

        XCTAssertEqual(result, .unavailable(.requiresMacOS26))
        let state = await dependencies.state()
        XCTAssertTrue(state.savedRuns.isEmpty)
        XCTAssertNil(state.replacedArtifacts)
    }

    func testPublicationFailurePreservesPreviousSnapshot() async {
        let fixture = Fixture()
        let dependencies = Dependencies(
            result: .pass(CompanionRegenerationPass(
                artifacts: [fixture.artifact()],
                completed: true)),
            failsReplacement: true)

        let result = await RegenerateCompanionCards(
            store: dependencies,
            provider: dependencies).execute(fixture.request)

        XCTAssertEqual(result, .persistenceFailed)
        let state = await dependencies.state()
        XCTAssertNil(state.replacedArtifacts)
    }
}

private struct Fixture {
    let meetingID = MeetingID()
    let sourceID = UUID()

    var material: MeetingTranscriptGenerationMaterial {
        let segment = TranscriptSegment(
            id: sourceID,
            meetingID: meetingID,
            channel: .system,
            text: "¿Cuándo?",
            startTime: 1,
            endTime: 2,
            isFinal: true)
        return MeetingTranscriptGenerationMaterial(
            segments: [segment],
            sourceSegmentIDsByGeneratedID: [sourceID: [sourceID]],
            baseTranscriptRevision: 4,
            correctionRevision: .accepted)
    }

    var request: RegenerateCompanionCardsRequest {
        RegenerateCompanionCardsRequest(meetingID: meetingID, material: material)
    }

    func artifact() -> CompanionGenerationArtifact {
        CompanionGenerationArtifact(
            card: CompanionCard(
                question: "¿Cuándo?",
                answer: "El lunes.",
                kind: .context,
                source: "on-device",
                askedAt: 1),
            generationRun: run(outcome: .succeeded))
    }

    func run(outcome: GenerationRunOutcome) -> GenerationRun {
        GenerationRun(
            meetingID: meetingID,
            kind: .companion,
            providerID: "foundation-models",
            modelID: "system-language-model",
            inputFingerprint: "fixture",
            configJSON: "{}",
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            outcome: outcome,
            metricsJSON: outcome == .succeeded ? "{}" : nil)
    }
}

private actor Dependencies: CompanionRegenerationProvider, CompanionRegenerationStore {
    struct State {
        var savedRuns: [GenerationRun]
        var savedSourceRevision: Int?
        var replacedArtifacts: [CompanionGenerationArtifact]?
    }

    private let result: CompanionRegenerationProviderResult
    private let failsRunSave: Bool
    private let failsReplacement: Bool
    private var savedRuns: [GenerationRun] = []
    private var savedSourceRevision: Int?
    private var replacedArtifacts: [CompanionGenerationArtifact]?

    init(
        result: CompanionRegenerationProviderResult,
        failsRunSave: Bool = false,
        failsReplacement: Bool = false
    ) {
        self.result = result
        self.failsRunSave = failsRunSave
        self.failsReplacement = failsReplacement
    }

    func regenerate(
        _ request: RegenerateCompanionCardsRequest
    ) -> CompanionRegenerationProviderResult {
        result
    }

    func saveCompanionRegenerationRun(
        _ run: GenerationRun,
        sourceTranscriptRevision: Int
    ) throws {
        if failsRunSave { throw PersistenceFailure() }
        savedRuns.append(run)
        savedSourceRevision = sourceTranscriptRevision
    }

    func replaceRegeneratedCompanionCards(
        _ artifacts: [CompanionGenerationArtifact],
        for meetingID: MeetingID
    ) throws {
        if failsReplacement { throw PersistenceFailure() }
        replacedArtifacts = artifacts
    }

    func state() -> State {
        State(
            savedRuns: savedRuns,
            savedSourceRevision: savedSourceRevision,
            replacedArtifacts: replacedArtifacts)
    }
}

private struct PersistenceFailure: Error {}
