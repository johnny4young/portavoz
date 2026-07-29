import Foundation
import XCTest
@testable import portavoz_app

final class UITestDefaultsTests: XCTestCase {
    func testStorageIsolationKeepsAutomationModelsDisposable() {
        let policy = AppStorageIsolationPolicy(
            arguments: ["Portavoz", "-use-temp-store", "-seed-demo"])

        XCTAssertTrue(policy.usesTemporaryMeetingStore)
        XCTAssertTrue(policy.usesTemporaryModelStore)
        XCTAssertTrue(policy.usesTemporarySensitiveStore)
    }

    func testRecordingBenchmarkReusesModelsButKeepsMeetingStoreDisposable() {
        let policy = AppStorageIsolationPolicy(
            arguments: [
                "Portavoz", "-use-temp-store", "--bench-record", "60",
            ])

        XCTAssertTrue(policy.usesTemporaryMeetingStore)
        XCTAssertFalse(policy.usesTemporaryModelStore)
        XCTAssertTrue(policy.usesTemporarySensitiveStore)
    }

    func testRecordingIndexingBenchmarkReusesOnlyRecordingModels() {
        let policy = AppStorageIsolationPolicy(
            arguments: [
                "Portavoz", "-use-temp-store",
                "--bench-record", "60",
                "--bench-resource-recording-indexing",
            ])

        XCTAssertTrue(policy.usesTemporaryMeetingStore)
        XCTAssertFalse(policy.usesTemporaryModelStore)
        XCTAssertTrue(policy.usesTemporarySensitiveStore)
    }

    func testRecordingBatchBenchmarkReusesOnlyRecordingModels() {
        let policy = AppStorageIsolationPolicy(
            arguments: [
                "Portavoz", "-use-temp-store",
                "--bench-record", "60",
                "--bench-resource-recording-batch", "/tmp/fixture.aiff",
            ])

        XCTAssertTrue(policy.usesTemporaryMeetingStore)
        XCTAssertFalse(policy.usesTemporaryModelStore)
        XCTAssertTrue(policy.usesTemporarySensitiveStore)
    }

    func testRefineResourceBenchmarkReusesVerifiedModelsOnly() {
        let policy = AppStorageIsolationPolicy(
            arguments: [
                "Portavoz", "-use-temp-store",
                "--bench-resource-refine", "/tmp/fixture.aiff",
            ])

        XCTAssertTrue(policy.usesTemporaryMeetingStore)
        XCTAssertFalse(policy.usesTemporaryModelStore)
        XCTAssertTrue(policy.usesTemporarySensitiveStore)
    }

    func testSummaryResourceBenchmarkReusesVerifiedModelsOnly() {
        let policy = AppStorageIsolationPolicy(
            arguments: [
                "Portavoz", "-use-temp-store",
                "--bench-resource-summary",
            ])

        XCTAssertTrue(policy.usesTemporaryMeetingStore)
        XCTAssertFalse(policy.usesTemporaryModelStore)
        XCTAssertTrue(policy.usesTemporarySensitiveStore)
    }

    func testAskResourceBenchmarkNeedsNoPortavozModelCache() {
        let policy = AppStorageIsolationPolicy(
            arguments: [
                "Portavoz", "-use-temp-store",
                "--bench-resource-ask",
            ])

        XCTAssertTrue(policy.usesTemporaryMeetingStore)
        XCTAssertTrue(policy.usesTemporaryModelStore)
        XCTAssertTrue(policy.usesTemporarySensitiveStore)
    }

    func testIndexingResourceBenchmarkNeedsNoPortavozModelCache() {
        let policy = AppStorageIsolationPolicy(
            arguments: [
                "Portavoz", "-use-temp-store",
                "--bench-resource-indexing",
            ])

        XCTAssertTrue(policy.usesTemporaryMeetingStore)
        XCTAssertTrue(policy.usesTemporaryModelStore)
        XCTAssertTrue(policy.usesTemporarySensitiveStore)
    }

    func testTemporaryStoreLaunchInstallsVolatileOverrides() throws {
        let suiteName = "UITestDefaultsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(false, forKey: "globalDictationEnabled")
        UITestDefaults.installIfNeeded(
            arguments: ["Portavoz", "-use-temp-store"],
            environment: [
                UITestDefaults.environmentKey:
                    #"{"globalDictationEnabled":true,"dictationMouseButton":4}"#
            ],
            defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: "globalDictationEnabled"))
        XCTAssertEqual(defaults.integer(forKey: "dictationMouseButton"), 4)
        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName)?["dictationMouseButton"])
    }

    func testOrdinaryLaunchAndMalformedPayloadAreIgnored() throws {
        let storagePolicy = AppStorageIsolationPolicy(
            arguments: ["Portavoz"])
        XCTAssertFalse(storagePolicy.usesTemporaryMeetingStore)
        XCTAssertFalse(storagePolicy.usesTemporaryModelStore)
        XCTAssertFalse(storagePolicy.usesTemporarySensitiveStore)

        let suiteName = "UITestDefaultsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suiteName)
        }

        UITestDefaults.installIfNeeded(
            arguments: ["Portavoz"],
            environment: [UITestDefaults.environmentKey: #"{"enabled":true}"#],
            defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "enabled"))

        UITestDefaults.installIfNeeded(
            arguments: ["Portavoz", "-use-temp-store"],
            environment: [UITestDefaults.environmentKey: "not-json"],
            defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "enabled"))
    }
}
