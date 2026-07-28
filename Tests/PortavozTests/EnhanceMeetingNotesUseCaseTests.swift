@testable import ApplicationKit
import IntelligenceKit
import PortavozCore
import StorageKit
import XCTest

final class EnhanceMeetingNotesUseCaseTests: XCTestCase {
    func testEnhancementSendsNotesRecipeWithStoredNotesAndPersistsAtomically() async throws {
        let fixture = Fixture(targetLanguage: "es", override: .mlx)
        let blank = ContextItem(
            meetingID: fixture.meetingID, kind: .note, content: "   ", timestamp: 3)
        let link = ContextItem(
            meetingID: fixture.meetingID,
            kind: .link,
            content: "https://example.com/rollout",
            timestamp: 5)
        let store = EnhancedNotesStoreSpy(contextItems: [fixture.note, blank, link])
        let provider = EnhancementProviderSpy(markdown: "# enhanced")
        let resolver = EnhancementResolverSpy(resolution: .available(provider))
        let runID = GenerationRunID()
        let timestamp = Date(timeIntervalSince1970: 42)
        let useCase = EnhanceMeetingNotes(
            store: store,
            preferences: EnhancementPreferencesStub(glossary: ["Portavoz"]),
            providers: resolver,
            makeGenerationRunID: { runID },
            now: { timestamp })

        let result = await useCase.execute(fixture.request)

        let requests = await provider.recordedRequests()
        let overrides = await resolver.recordedOverrides()
        let notes = await store.recordedSavedNotes()
        let runs = await store.recordedAtomicRuns()
        XCTAssertEqual(result, .completed(persisted: true))
        XCTAssertEqual(overrides, [.mlx])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.recipe.id, "enhanced-notes")
        XCTAssertEqual(requests.first?.targetLanguage, "es")
        XCTAssertEqual(requests.first?.glossary, ["Portavoz"])
        // Blank notes are dropped BEFORE fingerprinting, so trimming a
        // whitespace-only note later cannot fake a material change — and
        // non-note kinds (links, objectives, snippets) never enter the
        // enhancement material at all.
        XCTAssertEqual(
            requests.first?.contextItems.map(\.content), ["Expand the rollout risk"])
        XCTAssertEqual(notes.map(\.markdown), ["# enhanced"])
        XCTAssertEqual(notes.map(\.language), ["es"])
        XCTAssertEqual(notes.map(\.createdAt), [timestamp])
        XCTAssertEqual(
            notes.first?.inputFingerprint,
            requests.first.map {
                SummaryFingerprint.compute(request: $0, providerID: "direct-test")
            })
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.id, runID)
        XCTAssertEqual(runs.first?.kind, .enhancedNotes)
        XCTAssertEqual(runs.first?.outcome, .succeeded)
        XCTAssertEqual(runs.first?.outputLanguage, "es")
        XCTAssertEqual(runs.first?.inputFingerprint, notes.first?.inputFingerprint)
        XCTAssertEqual(
            runs.first?.configJSON,
            #"{"noteCount":"1","operation":"enhance-notes","recipeID":"enhanced-notes","workflow":"manual-enhancement"}"#)
        XCTAssertEqual(runs.first?.metricsJSON, #"{"outputUTF8Bytes":"10"}"#)
        let standalone = await store.recordedStandaloneRuns()
        XCTAssertTrue(standalone.isEmpty)
    }

    func testMeetingWithoutUsableNotesAnswersHonestlyBeforeResolvingAnyProvider() async {
        let fixture = Fixture()
        let blank = ContextItem(
            meetingID: fixture.meetingID, kind: .note, content: " ", timestamp: 1)
        let link = ContextItem(
            meetingID: fixture.meetingID,
            kind: .link,
            content: "https://example.com",
            timestamp: 2)
        let store = EnhancedNotesStoreSpy(contextItems: [blank, link])
        let resolver = EnhancementResolverSpy(
            resolution: .unavailable(.ollamaModelNotSelected))
        let useCase = EnhanceMeetingNotes(
            store: store,
            preferences: EnhancementPreferencesStub(),
            providers: resolver)

        let result = await useCase.execute(fixture.request)

        let overrides = await resolver.recordedOverrides()
        let notes = await store.recordedSavedNotes()
        let standalone = await store.recordedStandaloneRuns()
        XCTAssertEqual(result, .noNotes)
        XCTAssertTrue(overrides.isEmpty)
        XCTAssertTrue(notes.isEmpty)
        XCTAssertTrue(standalone.isEmpty)
    }

    func testExactFingerprintAndLanguageHitCreatesNoRun() async {
        let fixture = Fixture(targetLanguage: "es")
        let fingerprint = SummaryFingerprint.compute(
            request: fixture.summaryRequest(glossary: []),
            providerID: "direct-test")
        let store = EnhancedNotesStoreSpy(
            contextItems: [fixture.note],
            existing: EnhancedNote(
                meetingID: fixture.meetingID,
                markdown: "# stored",
                language: "es",
                inputFingerprint: fingerprint))
        let provider = EnhancementProviderSpy(markdown: "# fresh")
        let useCase = EnhanceMeetingNotes(
            store: store,
            preferences: EnhancementPreferencesStub(),
            providers: EnhancementResolverSpy(resolution: .available(provider)))

        let result = await useCase.execute(fixture.request)

        let requests = await provider.recordedRequests()
        let notes = await store.recordedSavedNotes()
        let runs = await store.recordedAtomicRuns()
        let standalone = await store.recordedStandaloneRuns()
        XCTAssertEqual(result, .unchanged)
        XCTAssertTrue(requests.isEmpty, "a cache hit must not call the model")
        XCTAssertTrue(notes.isEmpty)
        XCTAssertTrue(runs.isEmpty, "no model operation means no GenerationRun (D62)")
        XCTAssertTrue(standalone.isEmpty)
    }

    func testSameMaterialInAnotherLanguageRegenerates() async {
        let fixture = Fixture(targetLanguage: "en")
        let fingerprint = SummaryFingerprint.compute(
            request: fixture.summaryRequest(glossary: []),
            providerID: "direct-test")
        let store = EnhancedNotesStoreSpy(
            contextItems: [fixture.note],
            existing: EnhancedNote(
                meetingID: fixture.meetingID,
                markdown: "# almacenado",
                language: "es",
                inputFingerprint: fingerprint))
        let provider = EnhancementProviderSpy(markdown: "# fresh")
        let useCase = EnhanceMeetingNotes(
            store: store,
            preferences: EnhancementPreferencesStub(),
            providers: EnhancementResolverSpy(resolution: .available(provider)))

        let result = await useCase.execute(fixture.request)

        let notes = await store.recordedSavedNotes()
        XCTAssertEqual(result, .completed(persisted: true))
        XCTAssertEqual(notes.map(\.markdown), ["# fresh"])
        XCTAssertEqual(notes.map(\.language), ["en"])
    }

    func testProviderFailureRecordsBestEffortFailedRunAndSavesNoNote() async {
        let fixture = Fixture()
        let store = EnhancedNotesStoreSpy(contextItems: [fixture.note])
        let provider = EnhancementProviderSpy(markdown: "# never", summarizeFails: true)
        let useCase = EnhanceMeetingNotes(
            store: store,
            preferences: EnhancementPreferencesStub(),
            providers: EnhancementResolverSpy(resolution: .available(provider)))

        let result = await useCase.execute(fixture.request)

        let notes = await store.recordedSavedNotes()
        let standalone = await store.recordedStandaloneRuns()
        XCTAssertEqual(result, .generationFailed(.localModelNotice))
        XCTAssertTrue(notes.isEmpty)
        XCTAssertEqual(standalone.map(\.outcome), [.failed])
        XCTAssertEqual(standalone.map(\.kind), [.enhancedNotes])
        XCTAssertEqual(standalone.map(\.metricsJSON), [nil])
    }

    func testCancellationRecordsCancelledRunNotFailure() async {
        let fixture = Fixture()
        let store = EnhancedNotesStoreSpy(contextItems: [fixture.note])
        let provider = EnhancementProviderSpy(markdown: "# never", summarizeCancels: true)
        let useCase = EnhanceMeetingNotes(
            store: store,
            preferences: EnhancementPreferencesStub(),
            providers: EnhancementResolverSpy(resolution: .available(provider)))

        let result = await useCase.execute(fixture.request)

        let standalone = await store.recordedStandaloneRuns()
        XCTAssertEqual(result, .generationFailed(.localModelNotice))
        XCTAssertEqual(standalone.map(\.outcome), [.cancelled])
    }

    func testUnavailableProviderReturnsReasonWithoutStorageWrite() async {
        let fixture = Fixture()
        let store = EnhancedNotesStoreSpy(contextItems: [fixture.note])
        let useCase = EnhanceMeetingNotes(
            store: store,
            preferences: EnhancementPreferencesStub(),
            providers: EnhancementResolverSpy(
                resolution: .unavailable(.mlxModelNotDownloaded)))

        let result = await useCase.execute(fixture.request)

        let notes = await store.recordedSavedNotes()
        let standalone = await store.recordedStandaloneRuns()
        XCTAssertEqual(result, .unavailable(.mlxModelNotDownloaded))
        XCTAssertTrue(notes.isEmpty)
        XCTAssertTrue(standalone.isEmpty)
    }

    func testAtomicPersistenceFailureIsReportedAsUnpersisted() async {
        let fixture = Fixture()
        let store = EnhancedNotesStoreSpy(contextItems: [fixture.note], saveFails: true)
        let provider = EnhancementProviderSpy(markdown: "# enhanced")
        let useCase = EnhanceMeetingNotes(
            store: store,
            preferences: EnhancementPreferencesStub(),
            providers: EnhancementResolverSpy(resolution: .available(provider)))

        let result = await useCase.execute(fixture.request)

        XCTAssertEqual(result, .completed(persisted: false))
    }
}

// MARK: - Fixtures and spies

private struct Fixture {
    let meetingID = MeetingID()
    let speaker: Speaker
    let segment: TranscriptSegment
    let note: ContextItem
    let targetLanguage: String
    let override: SummaryEngine?

    init(targetLanguage: String = "en", override: SummaryEngine? = nil) {
        let meetingID = self.meetingID
        let speaker = Speaker(meetingID: meetingID, label: "S1", displayName: "Ana")
        self.speaker = speaker
        segment = TranscriptSegment(
            meetingID: meetingID,
            speakerID: speaker.id,
            channel: .system,
            text: "We agreed on the rollout",
            language: "en",
            startTime: 0,
            endTime: 3,
            isFinal: true)
        note = ContextItem(
            meetingID: meetingID,
            kind: .note,
            content: "Expand the rollout risk",
            timestamp: 12)
        self.targetLanguage = targetLanguage
        self.override = override
    }

    var request: EnhanceMeetingNotesRequest {
        EnhanceMeetingNotesRequest(
            meetingID: meetingID,
            segments: [segment],
            speakers: [speaker],
            targetLanguage: targetLanguage,
            providerOverride: override)
    }

    /// The exact request the use case is expected to hand the provider.
    func summaryRequest(glossary: [String]) -> SummaryRequest {
        SummaryRequest(
            meetingID: meetingID,
            segments: [segment],
            speakers: [speaker],
            recipe: EnhanceMeetingNotes.notesRecipe,
            targetLanguage: targetLanguage,
            glossary: glossary,
            contextItems: [note])
    }
}

private struct EnhancementPreferencesStub: SummaryRegenerationPreferences {
    let value: [String]

    init(glossary: [String] = []) {
        value = glossary
    }

    func glossary() -> [String] { value }
}

private actor EnhancementResolverSpy: SummaryRegenerationProviderResolver {
    private let resolution: SummaryRegenerationProviderResolution
    private var overrides: [SummaryEngine?] = []

    init(resolution: SummaryRegenerationProviderResolution) {
        self.resolution = resolution
    }

    func resolve(override: SummaryEngine?) -> SummaryRegenerationProviderResolution {
        overrides.append(override)
        return resolution
    }

    func recordedOverrides() -> [SummaryEngine?] { overrides }
}

private actor EnhancementProviderSpy: SummaryRegenerationProvider {
    struct Failure: Error {}

    nonisolated let providerID = "direct-test"
    nonisolated let modelID = "test-model"
    nonisolated let modelRevision: String? = "test-revision"
    nonisolated let reusePolicy = SummaryRegenerationReusePolicy.none
    nonisolated let failurePresentation = SummaryRegenerationFailurePresentation
        .localModelNotice
    private let markdown: String
    private let summarizeFails: Bool
    private let summarizeCancels: Bool
    private var requests: [SummaryRequest] = []

    init(markdown: String, summarizeFails: Bool = false, summarizeCancels: Bool = false) {
        self.markdown = markdown
        self.summarizeFails = summarizeFails
        self.summarizeCancels = summarizeCancels
    }

    func summarize(_ request: SummaryRequest) throws -> SummaryDraft {
        requests.append(request)
        if summarizeCancels { throw CancellationError() }
        if summarizeFails { throw Failure() }
        return SummaryDraft(
            meetingID: request.meetingID,
            recipeID: request.recipe.id,
            language: request.targetLanguage,
            markdown: markdown,
            actionItems: [],
            fingerprint: nil)
    }

    func translate(
        _ pivot: SummaryDraft,
        to targetLanguage: String,
        glossary: [String]
    ) throws -> SummaryDraft {
        throw Failure()
    }

    func recordedRequests() -> [SummaryRequest] { requests }
}

private actor EnhancedNotesStoreSpy: EnhancedNotesStore {
    struct Failure: Error {}

    private let items: [ContextItem]
    private let existing: EnhancedNote?
    private let saveFails: Bool
    private var savedNotes: [EnhancedNote] = []
    private var atomicRuns: [GenerationRun] = []
    private var standaloneRuns: [GenerationRun] = []

    init(
        contextItems: [ContextItem] = [],
        existing: EnhancedNote? = nil,
        saveFails: Bool = false
    ) {
        items = contextItems
        self.existing = existing
        self.saveFails = saveFails
    }

    func enhancementContextItems(for meetingID: MeetingID) -> [ContextItem] { items }

    func currentEnhancedNote(for meetingID: MeetingID) -> EnhancedNote? { existing }

    func saveEnhancedNote(_ note: EnhancedNote, generationRun: GenerationRun) throws {
        if saveFails { throw Failure() }
        savedNotes.append(note)
        atomicRuns.append(generationRun)
    }

    func saveEnhancementRun(_ run: GenerationRun) {
        standaloneRuns.append(run)
    }

    func recordedSavedNotes() -> [EnhancedNote] { savedNotes }
    func recordedAtomicRuns() -> [GenerationRun] { atomicRuns }
    func recordedStandaloneRuns() -> [GenerationRun] { standaloneRuns }
}
