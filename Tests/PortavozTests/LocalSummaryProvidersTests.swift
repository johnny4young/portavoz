import ApplicationKit
import XCTest

final class LocalSummaryProvidersTests: XCTestCase {
    func testAppleOnDeviceWinsOverOtherLocalProviders() {
        let recommendation = LocalSummaryProviderPolicy.recommendation(for: profile(
            apple: true,
            ollama: .running(models: [model("llama3.2")])) )

        XCTAssertEqual(
            recommendation.selection,
            LocalSummaryProviderSelection(engine: .appleOnDevice))
        XCTAssertEqual(recommendation.headline, .appleOnDevice)
    }

    func testOllamaRequiresAnEligibleSummaryModel() {
        let recommendation = LocalSummaryProviderPolicy.recommendation(for: profile(
            ollama: .running(models: [
                model("minicpm-v:ocr"),
                model("llama3.2:latest"),
            ])))

        XCTAssertEqual(
            recommendation.selection,
            LocalSummaryProviderSelection(
                engine: .ollama,
                ollamaModel: "llama3.2:latest"))
        XCTAssertEqual(recommendation.headline, .ollama)
    }

    func testOllamaWithoutEligibleSummaryModelFallsBackToBuiltIn() {
        let recommendation = LocalSummaryProviderPolicy.recommendation(for: profile(
            ollama: .running(models: [
                model("MINICPM-OCR"),
                model("nomic-embed-text"),
                model("qwen3-reranker"),
            ])))

        XCTAssertEqual(
            recommendation.selection,
            LocalSummaryProviderSelection(engine: .mlx))
        XCTAssertTrue(recommendation.reasons.contains(.ollamaHasNoEligibleModel))
        XCTAssertTrue(recommendation.reasons.contains(.builtInEligible))
    }

    func testBlankOllamaModelCannotBecomeAConfiguredProvider() {
        let recommendation = LocalSummaryProviderPolicy.recommendation(for: profile(
            ollama: .running(models: [model("  ")])))

        XCTAssertEqual(
            recommendation.selection,
            LocalSummaryProviderSelection(engine: .mlx))
        XCTAssertNil(
            LocalSummaryProviderSelection(engine: .ollama, ollamaModel: "  ")
                .ollamaModel)
    }

    func testNoCompatibleProviderRemainsExplicit() {
        let recommendation = LocalSummaryProviderPolicy.recommendation(for: profile(
            memoryGB: 4,
            freeDiskGB: 2,
            ollama: .unavailable))

        XCTAssertNil(recommendation.selection)
        XCTAssertEqual(recommendation.headline, .unavailable)
        XCTAssertTrue(recommendation.reasons.contains(.noCompatibleLocalProvider))
    }

    func testLowMemoryAndDiskReturnTypedGuidance() {
        let recommendation = LocalSummaryProviderPolicy.recommendation(for: profile(
            memoryGB: 8,
            freeDiskGB: 4,
            ollama: .running(models: [model("llama3.2")])))

        XCTAssertEqual(recommendation.selection?.engine, .ollama)
        XCTAssertTrue(recommendation.preferCompactWhisper)
        XCTAssertTrue(
            recommendation.reasons.contains(.lowMemoryForOllama(memoryGB: 8)))
        XCTAssertTrue(recommendation.reasons.contains(.lowDisk(freeDiskGB: 4)))
    }

    func testDiscoveryReturnsOneCoherentProbeAndRecommendation() async {
        let expected = profile(ollama: .running(models: [model("llama3.2")]))
        let result = await DiscoverLocalSummaryProviders(
            probe: StubLocalSummaryProviderProbe(profile: expected)
        ).execute(())

        XCTAssertEqual(result.profile, expected)
        XCTAssertEqual(result.recommendation.selection?.engine, .ollama)
    }

    func testInitialConfigurationNeverOverwritesExistingSelection() async {
        let existing = LocalSummaryProviderSelection(engine: .mlx)
        let store = StubSummaryProviderSelectionStore(selection: existing)
        let result = await ConfigureInitialSummaryProvider(
            probe: StubLocalSummaryProviderProbe(profile: profile(apple: true)),
            selections: store
        ).execute(())
        let snapshot = await store.snapshot()

        XCTAssertEqual(result, .alreadyConfigured)
        XCTAssertEqual(snapshot.selection, existing)
        XCTAssertEqual(snapshot.saveCount, 0)
    }

    func testInitialConfigurationPersistsRecommendedOllamaModel() async {
        let store = StubSummaryProviderSelectionStore()
        let result = await ConfigureInitialSummaryProvider(
            probe: StubLocalSummaryProviderProbe(profile: profile(
                ollama: .running(models: [model("ocr"), model("qwen3:8b")]))),
            selections: store
        ).execute(())
        let expected = LocalSummaryProviderSelection(
            engine: .ollama,
            ollamaModel: "qwen3:8b")
        let snapshot = await store.snapshot()

        XCTAssertEqual(result, .configured(expected))
        XCTAssertEqual(snapshot.selection, expected)
        XCTAssertEqual(snapshot.saveCount, 1)
    }

    func testInitialConfigurationDoesNotWriteAnImpossibleProvider() async {
        let store = StubSummaryProviderSelectionStore()
        let result = await ConfigureInitialSummaryProvider(
            probe: StubLocalSummaryProviderProbe(profile: profile(
                memoryGB: 4,
                freeDiskGB: 2)),
            selections: store
        ).execute(())
        let snapshot = await store.snapshot()

        XCTAssertEqual(result, .unavailable)
        XCTAssertNil(snapshot.selection)
        XCTAssertEqual(snapshot.saveCount, 0)
    }

    func testInitialConfigurationDoesNotClaimARejectedWrite() async {
        let store = StubSummaryProviderSelectionStore(rejectNextSave: true)
        let result = await ConfigureInitialSummaryProvider(
            probe: StubLocalSummaryProviderProbe(profile: profile(apple: true)),
            selections: store
        ).execute(())
        let snapshot = await store.snapshot()

        XCTAssertEqual(result, .alreadyConfigured)
        XCTAssertNil(snapshot.selection)
        XCTAssertEqual(snapshot.saveCount, 0)
    }

    private func profile(
        memoryGB: Int = 16,
        freeDiskGB: Int = 100,
        apple: Bool = false,
        ollama: LocalOllamaAvailability = .unavailable
    ) -> LocalSummaryProviderProfile {
        LocalSummaryProviderProfile(
            memoryGB: memoryGB,
            freeDiskGB: freeDiskGB,
            appleOnDeviceAvailable: apple,
            ollama: ollama)
    }

    private func model(_ name: String) -> LocalSummaryModel {
        LocalSummaryModel(name: name, parameterSize: "", bytes: 0)
    }
}

private struct StubLocalSummaryProviderProbe: LocalSummaryProviderProbing {
    let profile: LocalSummaryProviderProfile

    func probeLocalSummaryProviders() async -> LocalSummaryProviderProfile {
        profile
    }
}

private actor StubSummaryProviderSelectionStore: SummaryProviderSelectionStoring {
    private(set) var selection: LocalSummaryProviderSelection?
    private(set) var saveCount = 0
    private var rejectNextSave: Bool

    init(
        selection: LocalSummaryProviderSelection? = nil,
        rejectNextSave: Bool = false
    ) {
        self.selection = selection
        self.rejectNextSave = rejectNextSave
    }

    func summaryProviderSelection() async -> LocalSummaryProviderSelection? {
        selection
    }

    func saveInitialSummaryProviderSelection(
        _ selection: LocalSummaryProviderSelection
    ) async -> Bool {
        guard self.selection == nil, !rejectNextSave else {
            rejectNextSave = false
            return false
        }
        self.selection = selection
        saveCount += 1
        return true
    }

    func snapshot() -> (selection: LocalSummaryProviderSelection?, saveCount: Int) {
        (selection, saveCount)
    }
}
