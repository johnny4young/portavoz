import XCTest

final class UITestStorageUITests: PortavozUITestCase {
    private var ownedRoot: URL?

    override func tearDown() async throws {
        try await super.tearDown()
        if let ownedRoot {
            XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRoot.path))
        }
    }

    @MainActor
    func testSharedScratchProtectsOwnershipAndRoundTripsAppFixtures() throws {
        let otherOwner = UUID()
        XCTAssertThrowsError(try UITestStorage.begin(ownerID: otherOwner))
        try UITestStorage.end(ownerID: otherOwner)

        let allocationError = CocoaError(.fileWriteOutOfSpace)
        XCTAssertThrowsError(try XCUIApplication.portavoz(makeTemporaryDirectory: {
            throw allocationError
        })) { error in
            XCTAssertEqual(error as? CocoaError, allocationError)
        }

        let app = try XCUIApplication.portavoz(seedDemo: true)
        let temporaryPath = try XCTUnwrap(app.launchEnvironment["TMPDIR"])
        let temporaryRoot = URL(fileURLWithPath: temporaryPath, isDirectory: true)
        ownedRoot = temporaryRoot.deletingLastPathComponent()
        XCTAssertTrue(temporaryRoot.path.hasPrefix("/private/tmp/portavoz-ui-tests/portavoz-ui-"))
        for key in ["PORTAVOZ_UI_TEST_DATABASE_PATH", "PORTAVOZ_AUDIO_ROOT",
                    "PORTAVOZ_UI_TEST_SEED_READY_PATH"] {
            let path = try XCTUnwrap(app.launchEnvironment[key])
            XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent(), temporaryRoot)
        }
        app.launchPortavoz()
        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        // Library readiness already consumes the app-written one-shot marker.
        let readyPath = try XCTUnwrap(app.launchEnvironment["PORTAVOZ_UI_TEST_SEED_READY_PATH"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: readyPath))
        let audioRoot = URL(fileURLWithPath: try XCTUnwrap(app.launchEnvironment["PORTAVOZ_AUDIO_ROOT"]))
        let audio = audioRoot.appendingPathComponent("Audio")
        let entries = try FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 1)
        let recording = try XCTUnwrap(entries.first)
        for channel in ["microphone", "system"] {
            let bytes = try Data(contentsOf: recording.appendingPathComponent("\(channel).wav"))
            XCTAssertGreaterThan(bytes.count, 44, "the app must produce readable synthetic audio, not just a marker")
        }
    }
}
