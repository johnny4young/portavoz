import ApplicationKit
import Foundation
import XCTest

@testable import portavoz_app

@MainActor
final class PortableSettingsTests: XCTestCase {
    func testActualDefaultsExportExcludesSecretsConsentsAndHostBindings() async throws {
        let defaults = preferences()
        defaults.setVolatileDomain([
            "customVocabulary": "Cóndor, Don’t, C++", "dictationLanguage": "es",
            "globalDictationEnabled": true, "dictationHotkeyKeyCode": -1,
            "dictationMouseButton": 4, "byokAPIKey": "never-export-this",
            "byokEndpoint": "https://private.invalid", "companionUserName": "Private name",
            "mirrorAfterMeeting": true, "recordingsRoot": "/private/recordings",
            "menuBarEnabled": false,
        ], forName: UserDefaults.argumentDomain)
        let store = AppPortableSettingsStore(defaults: defaults, temporary: true)
        let data = try PortableSettingsTransfer.export(store.snapshot())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let values = try XCTUnwrap(object["settings"] as? [String: Any])
        XCTAssertEqual(Set(values.keys), Set(PortableSettingsKey.allCases.map(\.rawValue)))
        XCTAssertEqual(values["vocabulary"] as? String, "Cóndor, Don’t, C++")
        XCTAssertEqual(values["menuBarVisible"] as? Bool, false)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for excluded in ["never-export-this", "private.invalid", "Private name", "/private/recordings",
                         "dictation", "Dictation"] {
            XCTAssertFalse(text.contains(excluded), excluded)
        }
    }

    func testActualImportMergesVocabularyAndPreservesUnrelatedPreferences() async throws {
        let defaults = preferences()
        defaults.setVolatileDomain([
            "customVocabulary": "Existing, Cóndor", "globalDictationEnabled": false,
        ], forName: UserDefaults.argumentDomain)
        let store = AppPortableSettingsStore(defaults: defaults, temporary: true)
        let before = try store.snapshot()
        let data = try PortableSettingsTransfer.export([
            .vocabulary: .text("cóndor, New"), .titleTemplate: .text("{title}"),
        ])
        let review = try PortableSettingsTransfer.review(data, current: before)
        XCTAssertEqual(try store.snapshot(), before, "preview must never write")
        XCTAssertEqual(try store.apply(review, captureActive: false), 2)
        XCTAssertFalse(defaults.bool(forKey: "globalDictationEnabled"))
        XCTAssertEqual(defaults.string(forKey: "customVocabulary"), "Existing, Cóndor, New")
        XCTAssertEqual(defaults.string(forKey: "titleTemplate"), "{title}")
        XCTAssertThrowsError(try store.apply(review, captureActive: false)) {
            XCTAssertEqual($0 as? PortableSettingsFailure, .staleReview)
        }
    }

    func testAOneXExportStillImportsAndItsDictationKeysChangeNothing() async throws {
        let defaults = preferences()
        let store = AppPortableSettingsStore(defaults: defaults, temporary: true)
        let before = try store.snapshot()
        // Retired values are skipped before validation, so a value 2.0 would reject cannot fail the file.
        let raw = #"""
        {"format":"portavoz-settings","version":1,"settings":{"dictationLanguage":"fr","removeFillers":false,
        "replacements":"broken","vocabulary":"Cóndor"}}
        """#
        let review = try PortableSettingsTransfer.review(Data(raw.utf8), current: before)
        XCTAssertEqual(review.changes, [.vocabulary: .text("Cóndor")])
        XCTAssertEqual(try store.apply(review, captureActive: false), 1)
        for key in ["dictationLanguage", "dictationFillerFilter", "dictationReplacements"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        let unknown = #"{"format":"portavoz-settings","version":1,"settings":{"replacements":"[]","futureKey":true}}"#
        XCTAssertThrowsError(try PortableSettingsTransfer.review(Data(unknown.utf8), current: before)) {
            XCTAssertEqual($0 as? PortableSettingsFailure, .unsupportedSetting)
        }
    }

    func testApplyRechecksCaptureAndConcurrentChangesAtTheActualWriteSeam() async throws {
        let defaults = preferences()
        let store = AppPortableSettingsStore(defaults: defaults, temporary: true)
        let before = try store.snapshot()
        let file = try PortableSettingsTransfer.export([.titleTemplate: .text("{title}")])
        let review = try PortableSettingsTransfer.review(file, current: before)
        XCTAssertThrowsError(try store.apply(review, captureActive: true)) {
            XCTAssertEqual($0 as? PortableSettingsFailure, .captureActive)
        }
        XCTAssertEqual(try store.snapshot(), before)
        defaults.setVolatileDomain(["customVocabulary": "changed during review"], forName: UserDefaults.argumentDomain)
        XCTAssertThrowsError(try store.apply(review, captureActive: false)) {
            XCTAssertEqual($0 as? PortableSettingsFailure, .staleReview)
        }
        XCTAssertNil(defaults.object(forKey: "titleTemplate"))
    }

    func testProductionWriteBranchPersistsOnlyReviewedKeysAndRemovesOnlyTheirOverrides() async throws {
        let suite = "portable-settings-persistence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "globalDictationEnabled")
        defaults.set("private-existing-model", forKey: "byokModel")
        defaults.setVolatileDomain([
            "titleTemplate": "{date}", "unrelatedOverride": "retained",
        ], forName: UserDefaults.argumentDomain)
        let store = AppPortableSettingsStore(defaults: defaults, temporary: false)
        let before = try store.snapshot()
        let file = try PortableSettingsTransfer.export([.titleTemplate: .text("{title}")])
        let review = try PortableSettingsTransfer.review(file, current: before)
        XCTAssertEqual(try store.apply(review, captureActive: false), 1)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["titleTemplate"] as? String, "{title}")
        XCTAssertEqual(try store.snapshot()[.titleTemplate], .text("{title}"))
        XCTAssertTrue(defaults.bool(forKey: "globalDictationEnabled"), "existing consent is not revoked or imported")
        XCTAssertEqual(defaults.string(forKey: "byokModel"), "private-existing-model")
        XCTAssertEqual(defaults.volatileDomain(forName: UserDefaults.argumentDomain).count, 1)
        XCTAssertEqual(defaults.string(forKey: "unrelatedOverride"), "retained")
    }

    func testMalformedOrSensitiveFilesCannotReachDefaultsMutation() async throws {
        let defaults = preferences()
        let store = AppPortableSettingsStore(defaults: defaults, temporary: true)
        let before = try store.snapshot()
        for raw in [
            #"{"format":"portavoz-settings","version":1,"settings":{"globalDictationEnabled":true}}"#,
            #"{"format":"portavoz-settings","version":1,"settings":{"menuBarVisible":1}}"#,
            #"{"format":"portavoz-settings","version":1,"settings":{"menuBarVisible":"false"}}"#,
            #"{"format":"portavoz-settings","version":1,"settings":{"vocabulary":null}}"#,
            #"{"format":"portavoz-settings","version":2,"settings":{}}"#,
            #"{"format":"portavoz-settings","version":1,"settings":{},"consent":true}"#,
            #"{"format":"portavoz-settings","version":1,"settings":{"interfaceLanguage":"fr"}}"#,
        ] {
            XCTAssertThrowsError(try PortableSettingsTransfer.review(Data(raw.utf8), current: before))
            XCTAssertEqual(try store.snapshot(), before)
        }
    }

    func testEmptySnapshotIsAnExplicitNoOpAndOversizedValuesAreRefused() async throws {
        let store = AppPortableSettingsStore(defaults: preferences(), temporary: true)
        let before = try store.snapshot()
        let review = try PortableSettingsTransfer.review(PortableSettingsTransfer.export([:]), current: before)
        XCTAssertEqual(try store.apply(review, captureActive: false), 0)
        XCTAssertEqual(try store.snapshot(), before)
        XCTAssertThrowsError(try PortableSettingsTransfer.review(
            Data(repeating: 32, count: PortableSettingsValidation.maximumFileBytes + 1), current: before))
        let maximumText = String(repeating: "é", count: PortableSettingsValidation.maximumTextBytes / 2)
        let maximumFile = try PortableSettingsTransfer.export([.vocabulary: .text(maximumText)])
        let maximumReview = try PortableSettingsTransfer.review(maximumFile, current: before)
        XCTAssertEqual(maximumReview.changes[.vocabulary], .text(maximumText))
        XCTAssertThrowsError(try PortableSettingsTransfer.export([
            .vocabulary: .text(String(repeating: "é", count: PortableSettingsValidation.maximumTextBytes / 2 + 1)),
        ]))
    }

    func testEquivalentVocabularyPreservesStoredBytesAtTheActualWriteSeam() async throws {
        let defaults = preferences()
        defaults.setVolatileDomain(["customVocabulary": "  Cóndor , Don’t,, C++  "], forName: UserDefaults.argumentDomain)
        let store = AppPortableSettingsStore(defaults: defaults, temporary: true)
        let before = try store.snapshot()
        for incoming in ["", "cóndor, Don’t, c++"] {
            let file = try PortableSettingsTransfer.export([.vocabulary: .text(incoming)])
            let review = try PortableSettingsTransfer.review(file, current: before)
            XCTAssertTrue(review.changes.isEmpty, "serialization is not a preference change")
            XCTAssertEqual(try store.apply(review, captureActive: false), 0)
            XCTAssertEqual(try store.snapshot(), before, "no-op import must not rewrite stored bytes")
        }
    }

    private func preferences() -> UserDefaults {
        let suite = "portable-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        return defaults
    }
}
