import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class AppleSpeechPreparationModelTests: XCTestCase {
    func testReadOnlyInspectionAndExplicitPreparationAreSeparate() async throws {
        let client = try XCTUnwrap(AppleSpeechUITestFixture.make(
            arguments: ["-use-temp-store", "-seed-apple-speech-settings"],
            usesTemporaryStore: true))
        let model = AppleSpeechPreparationModel(client: client)
        XCTAssertEqual(model.phase(for: nil), .languageRequired)
        await model.refresh(language: "es")
        XCTAssertEqual(model.phase(for: "es"), .needsDownload)
        XCTAssertEqual(model.phase(for: "en"), .checking)
        await model.prepare(language: "es")
        XCTAssertEqual(model.phase(for: "es"), .ready)
        await model.refresh(language: "en")
        XCTAssertEqual(model.phase(for: "en"), .needsDownload)
        XCTAssertEqual(model.phase(for: "es"), .ready)
    }

    func testFixtureCannotBeEnabledOutsideDisposableApp() async {
        XCTAssertNil(AppleSpeechUITestFixture.make(
            arguments: ["-seed-apple-speech-settings"], usesTemporaryStore: false))
        XCTAssertNil(AppleSpeechUITestFixture.make(
            arguments: ["-use-temp-store"], usesTemporaryStore: true))
    }

    func testAssetPreparationRefusesAnActiveRecordingBeforeAnyOSRequest() async {
        let capture = AppResourceCaptureState()
        capture.update(.active)
        let client = AppAppleSpeechPreparationClient(captureState: capture)
        do {
            try await client.prepare(language: "en")
            XCTFail("Asset downloads must not start during capture")
        } catch AppResourceGovernorAdmissionError.activeCaptureModelConflict {
            // The guard runs before AssetInventory on every macOS version.
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
    }

    func testAnotherLanguageCannotOfferAnInertPrepareWhileOneIsInFlight() async {
        let client = SuspendedApplePreparationClient()
        let model = AppleSpeechPreparationModel(client: client)
        await model.refresh(language: "en")
        await model.refresh(language: "es")
        let first = Task { await model.prepare(language: "en") }
        await client.waitUntilPreparing()
        XCTAssertTrue(model.isPreparingAnotherLanguage("es"))
        XCTAssertFalse(model.isPreparingAnotherLanguage("en"))
        await model.prepare(language: "es")
        XCTAssertEqual(client.prepareCalls, ["en"])
        client.resume()
        await first.value
        XCTAssertFalse(model.isPreparingAnotherLanguage("es"))
    }
}

@MainActor
private final class SuspendedApplePreparationClient: AppleSpeechPreparationClient {
    private var waiter: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private(set) var prepareCalls: [String] = []

    func current(language: String?) async throws -> SpeechAnalyzerLiveReadiness {
        .needsDownload(language == "es" ? "es_ES" : "en_US")
    }

    func prepare(language: String) async throws {
        prepareCalls.append(language)
        await withCheckedContinuation {
            waiter = $0
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }

    func waitUntilPreparing() async {
        if waiter != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func resume() {
        waiter?.resume()
        waiter = nil
    }
}
