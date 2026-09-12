import ApplicationKit
import Foundation
import TranscriptionKit
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
                         "globalDictationEnabled", "dictationHotkeyKeyCode", "dictationMouseButton"] {
            XCTAssertFalse(text.contains(excluded), excluded)
        }
    }

    func testActualImportMergesCollectionsAndPreservesUnrelatedPreferences() async throws {
        let defaults = preferences()
        defaults.setVolatileDomain([
            "customVocabulary": "Existing, Cóndor", "globalDictationEnabled": false,
            "dictationReplacements": DictationTextRules.encode([
                .init(trigger: "old", replacement: "Old"), .init(trigger: "c++", replacement: "old spelling"),
            ]),
        ], forName: UserDefaults.argumentDomain)
        let store = AppPortableSettingsStore(defaults: defaults, temporary: true)
        let before = try store.snapshot()
        let data = try PortableSettingsTransfer.export([
            .vocabulary: .text("cóndor, New"), .dictationLanguage: .text("es"), .removeFillers: .flag(false),
            .replacements: .text(DictationTextRules.encode([.init(trigger: "C++", replacement: "C++ $1 \\" )])),
        ])
        let review = try PortableSettingsTransfer.review(data, current: before)
        XCTAssertEqual(try store.snapshot(), before, "preview must never write")
        XCTAssertEqual(try store.apply(review, captureActive: false), 4)
        XCTAssertFalse(defaults.bool(forKey: "globalDictationEnabled"))
        XCTAssertEqual(defaults.string(forKey: "customVocabulary"), "Existing, Cóndor, New")
        let rules = DictationTextRules.decode(replacements: defaults.string(forKey: "dictationReplacements") ?? "")
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules.first?.trigger, "old")
        XCTAssertEqual(rules.last?.replacement, "C++ $1 \\")
        XCTAssertEqual(try store.snapshot()[.dictationLanguage], .text("es"))
        XCTAssertThrowsError(try store.apply(review, captureActive: false)) {
            XCTAssertEqual($0 as? PortableSettingsFailure, .staleReview)
        }
    }

    func testApplyRechecksCaptureAndConcurrentChangesAtTheActualWriteSeam() async throws {
        let defaults = preferences()
        let store = AppPortableSettingsStore(defaults: defaults, temporary: true)
        let before = try store.snapshot()
        let file = try PortableSettingsTransfer.export([.dictationLanguage: .text("en")])
        let review = try PortableSettingsTransfer.review(file, current: before)
        XCTAssertThrowsError(try store.apply(review, captureActive: true)) {
            XCTAssertEqual($0 as? PortableSettingsFailure, .captureActive)
        }
        XCTAssertEqual(try store.snapshot(), before)
        defaults.setVolatileDomain(["customVocabulary": "changed during review"], forName: UserDefaults.argumentDomain)
        XCTAssertThrowsError(try store.apply(review, captureActive: false)) {
            XCTAssertEqual($0 as? PortableSettingsFailure, .staleReview)
        }
        XCTAssertNil(defaults.object(forKey: "dictationLanguage"))
    }

    func testProductionWriteBranchPersistsOnlyReviewedKeysAndRemovesOnlyTheirOverrides() async throws {
        let suite = "portable-settings-persistence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "globalDictationEnabled")
        defaults.set("private-existing-model", forKey: "byokModel")
        defaults.setVolatileDomain([
            "dictationLanguage": "es", "unrelatedOverride": "retained",
        ], forName: UserDefaults.argumentDomain)
        let store = AppPortableSettingsStore(defaults: defaults, temporary: false)
        let before = try store.snapshot()
        let file = try PortableSettingsTransfer.export([.dictationLanguage: .text("en")])
        let review = try PortableSettingsTransfer.review(file, current: before)
        XCTAssertEqual(try store.apply(review, captureActive: false), 1)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["dictationLanguage"] as? String, "en")
        XCTAssertEqual(try store.snapshot()[.dictationLanguage], .text("en"))
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
            #"{"format":"portavoz-settings","version":1,"settings":{"removeFillers":1}}"#,
            #"{"format":"portavoz-settings","version":1,"settings":{"removeFillers":"false"}}"#,
            #"{"format":"portavoz-settings","version":1,"settings":{"vocabulary":null}}"#,
            #"{"format":"portavoz-settings","version":2,"settings":{}}"#,
            #"{"format":"portavoz-settings","version":1,"settings":{},"consent":true}"#,
            #"{"format":"portavoz-settings","version":1,"settings":{"replacements":"broken"}}"#,
            #"{"format":"portavoz-settings","version":1,"settings":{"dictationLanguage":"fr"}}"#,
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

    func testRuleLimitAppliesAfterMergeAndEmptyCollectionsDoNotEraseRules() async throws {
        let store = AppPortableSettingsStore(defaults: preferences(), temporary: true)
        let rules = (0..<1_000).map { DictationReplacement(trigger: "a\($0)", replacement: "b\($0)") }
        let file = try PortableSettingsTransfer.export([.replacements: .text(DictationTextRules.encode(rules))])
        try store.apply(PortableSettingsTransfer.review(file, current: store.snapshot()), captureActive: false)
        let replacement = try PortableSettingsTransfer.export([.replacements: .text(
            DictationTextRules.encode([.init(trigger: "a500", replacement: "new value")]))])
        let replacementReview = try PortableSettingsTransfer.review(replacement, current: store.snapshot())
        XCTAssertEqual(try store.apply(replacementReview, captureActive: false), 1)
        let before = try store.snapshot()
        let extra = try PortableSettingsTransfer.export([.replacements: .text(
            DictationTextRules.encode([.init(trigger: "one more", replacement: "rejected")]))])
        XCTAssertThrowsError(try PortableSettingsTransfer.review(extra, current: before))
        XCTAssertEqual(try store.snapshot(), before)
        let empty = try PortableSettingsTransfer.export([.replacements: .text("[]"), .vocabulary: .text("")])
        let emptyReview = try PortableSettingsTransfer.review(empty, current: before)
        XCTAssertEqual(try store.apply(emptyReview, captureActive: false), 0)
        XCTAssertEqual(try store.snapshot(), before)
    }

    private func preferences() -> UserDefaults {
        let suite = "portable-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        return defaults
    }
}
