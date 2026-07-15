import ApplicationKit
import IntelligenceKit
import PortavozCore
import StorageKit
import XCTest

final class SummaryRegenerationUseCaseTests: XCTestCase {
    func testDirectProviderReceivesOverrideRecipeGlossaryAndStoredNotes() async throws {
        let fixture = Fixture(recipe: .standup, targetLanguage: "es", override: .mlx)
        let note = ContextItem(
            meetingID: fixture.meetingID,
            kind: .note,
            content: "Expand the rollout risk",
            timestamp: 12)
        let store = SummaryRegenerationStoreSpy(contextItems: [note])
        let provider = SummaryRegenerationProviderSpy(
            summaryDraft: fixture.draft(markdown: "# direct"))
        let resolver = SummaryRegenerationProviderResolverSpy(
            resolution: .available(provider))
        let useCase = RegenerateSummary(
            store: store,
            preferences: SummaryRegenerationPreferencesStub(glossary: ["Portavoz", "rollout"]),
            providers: resolver)

        let result = await useCase.execute(fixture.request)

        let requests = await provider.recordedSummaryRequests()
        let overrides = await resolver.recordedOverrides()
        let lookups = await store.recordedLookups()
        let saved = await store.recordedDrafts()
        XCTAssertEqual(result, .completed(persisted: true))
        XCTAssertEqual(overrides, [.mlx])
        XCTAssertTrue(lookups.isEmpty)
        XCTAssertEqual(saved.map(\.markdown), ["# direct"])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.meetingID, fixture.meetingID)
        XCTAssertEqual(requests.first?.recipe.id, Recipe.standup.id)
        XCTAssertEqual(requests.first?.targetLanguage, "es")
        XCTAssertEqual(requests.first?.glossary, ["Portavoz", "rollout"])
        XCTAssertEqual(requests.first?.contextItems.map(\.content), ["Expand the rollout risk"])
    }

    func testDirectProviderFailureKeepsVisibleLocalModelPolicy() async {
        let fixture = Fixture()
        let store = SummaryRegenerationStoreSpy()
        let provider = SummaryRegenerationProviderSpy(
            failurePresentation: .localModelNotice,
            summaryDraft: fixture.draft(),
            summarizeFails: true)
        let useCase = RegenerateSummary(
            store: store,
            preferences: SummaryRegenerationPreferencesStub(),
            providers: SummaryRegenerationProviderResolverSpy(
                resolution: .available(provider)))

        let result = await useCase.execute(fixture.request)

        let saved = await store.recordedDrafts()
        XCTAssertEqual(result, .generationFailed(.localModelNotice))
        XCTAssertTrue(saved.isEmpty)
    }

    func testAppleReuseReturnsExactLanguageHitWithoutModelCall() async {
        let fixture = Fixture(targetLanguage: "es")
        let request = fixture.summaryRequest(glossary: ["Portavoz"], contextItems: [])
        let fingerprint = SummaryFingerprint.compute(request: request, providerID: "apple-test")
        let exact = SummaryRegenerationSnapshot(
            draft: fixture.draft(markdown: "# cached", fingerprint: fingerprint),
            version: 7)
        let store = SummaryRegenerationStoreSpy(exact: exact)
        let provider = SummaryRegenerationProviderSpy(
            providerID: "apple-test",
            reusePolicy: .fingerprintCacheAndTranslationPivot,
            failurePresentation: .silent,
            summaryDraft: fixture.draft())
        let useCase = RegenerateSummary(
            store: store,
            preferences: SummaryRegenerationPreferencesStub(glossary: ["Portavoz"]),
            providers: SummaryRegenerationProviderResolverSpy(
                resolution: .available(provider)))

        let result = await useCase.execute(fixture.request)

        let lookups = await store.recordedLookups()
        let summaryRequests = await provider.recordedSummaryRequests()
        let translations = await provider.recordedTranslations()
        XCTAssertEqual(result, .unchanged(version: 7))
        XCTAssertEqual(lookups, [.init(fingerprint: fingerprint, language: "es")])
        XCTAssertTrue(summaryRequests.isEmpty)
        XCTAssertTrue(translations.isEmpty)
    }

    func testAppleReuseTranslatesDifferentLanguagePivotBeforeSummarizing() async {
        let fixture = Fixture(targetLanguage: "es")
        let request = fixture.summaryRequest(glossary: ["API"], contextItems: [])
        let fingerprint = SummaryFingerprint.compute(request: request, providerID: "apple-test")
        let pivotDraft = fixture.draft(
            language: "en", markdown: "# pivot", fingerprint: fingerprint)
        let translated = fixture.draft(
            language: "es", markdown: "# traducido", fingerprint: fingerprint)
        let store = SummaryRegenerationStoreSpy(
            pivot: SummaryRegenerationSnapshot(draft: pivotDraft, version: 3))
        let provider = SummaryRegenerationProviderSpy(
            providerID: "apple-test",
            reusePolicy: .fingerprintCacheAndTranslationPivot,
            failurePresentation: .silent,
            summaryDraft: fixture.draft(),
            translatedDraft: translated)
        let useCase = RegenerateSummary(
            store: store,
            preferences: SummaryRegenerationPreferencesStub(glossary: ["API"]),
            providers: SummaryRegenerationProviderResolverSpy(
                resolution: .available(provider)))

        let result = await useCase.execute(fixture.request)

        let lookups = await store.recordedLookups()
        let translations = await provider.recordedTranslations()
        let summaryRequests = await provider.recordedSummaryRequests()
        let saved = await store.recordedDrafts()
        XCTAssertEqual(result, .completed(persisted: true))
        XCTAssertEqual(
            lookups,
            [
                .init(fingerprint: fingerprint, language: "es"),
                .init(fingerprint: fingerprint, language: nil),
            ])
        XCTAssertEqual(translations.map(\.targetLanguage), ["es"])
        XCTAssertEqual(translations.first?.glossary, ["API"])
        XCTAssertTrue(summaryRequests.isEmpty)
        XCTAssertEqual(saved.map(\.markdown), ["# traducido"])
    }

    func testFailedPivotTranslationFallsBackToFullSummary() async {
        let fixture = Fixture(targetLanguage: "es")
        let request = fixture.summaryRequest()
        let fingerprint = SummaryFingerprint.compute(request: request, providerID: "apple-test")
        let pivot = SummaryRegenerationSnapshot(
            draft: fixture.draft(language: "en", fingerprint: fingerprint),
            version: 2)
        let store = SummaryRegenerationStoreSpy(pivot: pivot)
        let provider = SummaryRegenerationProviderSpy(
            providerID: "apple-test",
            reusePolicy: .fingerprintCacheAndTranslationPivot,
            failurePresentation: .silent,
            summaryDraft: fixture.draft(markdown: "# full"),
            translateFails: true)
        let useCase = RegenerateSummary(
            store: store,
            preferences: SummaryRegenerationPreferencesStub(),
            providers: SummaryRegenerationProviderResolverSpy(
                resolution: .available(provider)))

        let result = await useCase.execute(fixture.request)

        let translations = await provider.recordedTranslations()
        let summaryRequests = await provider.recordedSummaryRequests()
        let saved = await store.recordedDrafts()
        XCTAssertEqual(result, .completed(persisted: true))
        XCTAssertEqual(translations.count, 1)
        XCTAssertEqual(summaryRequests.count, 1)
        XCTAssertEqual(saved.map(\.markdown), ["# full"])
    }

    func testAppleFullGenerationFailureRetainsSilentPolicy() async {
        let fixture = Fixture()
        let store = SummaryRegenerationStoreSpy()
        let provider = SummaryRegenerationProviderSpy(
            providerID: "apple-test",
            reusePolicy: .fingerprintCacheAndTranslationPivot,
            failurePresentation: .silent,
            summaryDraft: fixture.draft(),
            summarizeFails: true)
        let useCase = RegenerateSummary(
            store: store,
            preferences: SummaryRegenerationPreferencesStub(),
            providers: SummaryRegenerationProviderResolverSpy(
                resolution: .available(provider)))

        let result = await useCase.execute(fixture.request)

        let saved = await store.recordedDrafts()
        XCTAssertEqual(result, .generationFailed(.silent))
        XCTAssertTrue(saved.isEmpty)
    }

    func testUnavailableProviderReturnsReasonWithoutStorageWrite() async {
        let fixture = Fixture()
        let store = SummaryRegenerationStoreSpy()
        let useCase = RegenerateSummary(
            store: store,
            preferences: SummaryRegenerationPreferencesStub(),
            providers: SummaryRegenerationProviderResolverSpy(
                resolution: .unavailable(.appleOnDevice(reason: "disabled"))))

        let result = await useCase.execute(fixture.request)

        let saved = await store.recordedDrafts()
        XCTAssertEqual(result, .unavailable(.appleOnDevice(reason: "disabled")))
        XCTAssertTrue(saved.isEmpty)
    }

    func testReleasedBestEffortContextAndPersistencePolicyIsExplicit() async {
        let fixture = Fixture()
        let store = SummaryRegenerationStoreSpy(contextReadFails: true, saveFails: true)
        let provider = SummaryRegenerationProviderSpy(summaryDraft: fixture.draft())
        let useCase = RegenerateSummary(
            store: store,
            preferences: SummaryRegenerationPreferencesStub(),
            providers: SummaryRegenerationProviderResolverSpy(
                resolution: .available(provider)))

        let result = await useCase.execute(fixture.request)

        let requests = await provider.recordedSummaryRequests()
        XCTAssertEqual(result, .completed(persisted: false))
        XCTAssertEqual(requests.first?.contextItems.count, 0)
    }

    func testRealStoreAdapterLoadsNotesAndPersistsSnapshot() async throws {
        let fixture = Fixture()
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(id: fixture.meetingID, title: "Summary", startedAt: Date())
        let note = ContextItem(
            meetingID: fixture.meetingID,
            kind: .note,
            content: "Keep the customer quote",
            timestamp: 4)
        try await store.save(meeting)
        try await store.save([note])
        let provider = SummaryRegenerationProviderSpy(
            summaryDraft: fixture.draft(markdown: "# persisted"))
        let useCase = RegenerateSummary(
            store: store,
            preferences: SummaryRegenerationPreferencesStub(),
            providers: SummaryRegenerationProviderResolverSpy(
                resolution: .available(provider)))

        let result = await useCase.execute(fixture.request)

        let stored = try await store.summary(fixture.meetingID)
        let requests = await provider.recordedSummaryRequests()
        XCTAssertEqual(result, .completed(persisted: true))
        XCTAssertEqual(stored?.draft.markdown, "# persisted")
        XCTAssertEqual(requests.first?.contextItems.map(\.content), ["Keep the customer quote"])
    }
}

private struct Fixture {
    let meetingID = MeetingID()
    let speaker: Speaker
    let segment: TranscriptSegment
    let recipe: Recipe
    let targetLanguage: String
    let override: SummaryEngine?

    init(
        recipe: Recipe = .general,
        targetLanguage: String = "en",
        override: SummaryEngine? = nil
    ) {
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
        self.recipe = recipe
        self.targetLanguage = targetLanguage
        self.override = override
    }

    var request: RegenerateSummaryRequest {
        RegenerateSummaryRequest(
            meetingID: meetingID,
            segments: [segment],
            speakers: [speaker],
            recipe: recipe,
            targetLanguage: targetLanguage,
            providerOverride: override)
    }

    func summaryRequest(
        glossary: [String] = [],
        contextItems: [ContextItem] = []
    ) -> SummaryRequest {
        SummaryRequest(
            meetingID: meetingID,
            segments: [segment],
            speakers: [speaker],
            recipe: recipe,
            targetLanguage: targetLanguage,
            glossary: glossary,
            contextItems: contextItems)
    }

    func draft(
        language: String? = nil,
        markdown: String = "# summary",
        fingerprint: String? = nil
    ) -> SummaryDraft {
        SummaryDraft(
            meetingID: meetingID,
            recipeID: recipe.id,
            language: language ?? targetLanguage,
            markdown: markdown,
            actionItems: [],
            fingerprint: fingerprint)
    }
}

private struct SummaryRegenerationPreferencesStub: SummaryRegenerationPreferences {
    let value: [String]

    init(glossary: [String] = []) {
        value = glossary
    }

    func glossary() -> [String] { value }
}

private actor SummaryRegenerationProviderResolverSpy: SummaryRegenerationProviderResolver {
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

private actor SummaryRegenerationProviderSpy: SummaryRegenerationProvider {
    struct Failure: Error {}

    struct Translation: Sendable {
        let pivot: SummaryDraft
        let targetLanguage: String
        let glossary: [String]
    }

    nonisolated let providerID: String
    nonisolated let reusePolicy: SummaryRegenerationReusePolicy
    nonisolated let failurePresentation: SummaryRegenerationFailurePresentation
    private let summaryDraft: SummaryDraft
    private let translatedDraft: SummaryDraft
    private let summarizeFails: Bool
    private let translateFails: Bool
    private var summaryRequests: [SummaryRequest] = []
    private var translations: [Translation] = []

    init(
        providerID: String = "direct-test",
        reusePolicy: SummaryRegenerationReusePolicy = .none,
        failurePresentation: SummaryRegenerationFailurePresentation = .localModelNotice,
        summaryDraft: SummaryDraft,
        translatedDraft: SummaryDraft? = nil,
        summarizeFails: Bool = false,
        translateFails: Bool = false
    ) {
        self.providerID = providerID
        self.reusePolicy = reusePolicy
        self.failurePresentation = failurePresentation
        self.summaryDraft = summaryDraft
        self.translatedDraft = translatedDraft ?? summaryDraft
        self.summarizeFails = summarizeFails
        self.translateFails = translateFails
    }

    func summarize(_ request: SummaryRequest) throws -> SummaryDraft {
        summaryRequests.append(request)
        if summarizeFails { throw Failure() }
        return summaryDraft
    }

    func translate(
        _ pivot: SummaryDraft,
        to targetLanguage: String,
        glossary: [String]
    ) throws -> SummaryDraft {
        translations.append(
            Translation(
                pivot: pivot,
                targetLanguage: targetLanguage,
                glossary: glossary))
        if translateFails { throw Failure() }
        return translatedDraft
    }

    func recordedSummaryRequests() -> [SummaryRequest] { summaryRequests }
    func recordedTranslations() -> [Translation] { translations }
}

private actor SummaryRegenerationStoreSpy: SummaryRegenerationStore {
    struct Failure: Error {}

    struct Lookup: Equatable, Sendable {
        let fingerprint: String
        let language: String?
    }

    private let contextItems: [ContextItem]
    private let exact: SummaryRegenerationSnapshot?
    private let pivot: SummaryRegenerationSnapshot?
    private let contextReadFails: Bool
    private let saveFails: Bool
    private var lookups: [Lookup] = []
    private var savedDrafts: [SummaryDraft] = []

    init(
        contextItems: [ContextItem] = [],
        exact: SummaryRegenerationSnapshot? = nil,
        pivot: SummaryRegenerationSnapshot? = nil,
        contextReadFails: Bool = false,
        saveFails: Bool = false
    ) {
        self.contextItems = contextItems
        self.exact = exact
        self.pivot = pivot
        self.contextReadFails = contextReadFails
        self.saveFails = saveFails
    }

    func regenerationContextItems(for meetingID: MeetingID) throws -> [ContextItem] {
        if contextReadFails { throw Failure() }
        return contextItems
    }

    func regenerationSummary(
        _ meetingID: MeetingID,
        fingerprint: String,
        language: String?
    ) -> SummaryRegenerationSnapshot? {
        lookups.append(Lookup(fingerprint: fingerprint, language: language))
        return language == nil ? pivot : exact
    }

    func saveRegeneratedSummary(_ draft: SummaryDraft) throws {
        savedDrafts.append(draft)
        if saveFails { throw Failure() }
    }

    func recordedLookups() -> [Lookup] { lookups }
    func recordedDrafts() -> [SummaryDraft] { savedDrafts }
}
