import Foundation
import StorageKit

/// Storage isolation is selected once at process composition. UI automation
/// gets an empty model root as well as a disposable meeting database. The
/// hidden benchmarks that need Portavoz-managed models keep only the database
/// disposable and reuse the normal verified model cache so repeated Release
/// samples do not include a fresh model installation. OS-model-only Ask and
/// standalone indexing keep both Portavoz stores disposable.
struct AppStorageIsolationPolicy: Equatable {
    let usesTemporaryMeetingStore: Bool
    let usesTemporaryModelStore: Bool
    let usesTemporarySensitiveStore: Bool
    let meetingStoreURL: URL
    let simulatesDatabaseOpenFailure: Bool

    init(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        usesTemporaryMeetingStore = arguments.contains("-use-temp-store")
        usesTemporarySensitiveStore = usesTemporaryMeetingStore
        let reusesVerifiedModels = arguments.contains("--bench-record")
            || arguments.contains("--bench-resource-prepare-refine")
            || arguments.contains("--bench-resource-refine")
            || arguments.contains("--bench-resource-summary")
        usesTemporaryModelStore =
            usesTemporaryMeetingStore && !reusesVerifiedModels
        if usesTemporaryMeetingStore {
            meetingStoreURL = environment["PORTAVOZ_UI_TEST_DATABASE_PATH"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                    "portavoz-uitest-\(UUID().uuidString).sqlite")
        } else {
            meetingStoreURL = MeetingStore.defaultDatabaseURL
        }
        simulatesDatabaseOpenFailure = usesTemporaryMeetingStore
            && arguments.contains("-simulate-database-open-failure")
    }
}

extension AppServices {
    static func prepareStoragePolicy(
        arguments: [String],
        environment: [String: String],
        override: AppStorageIsolationPolicy?,
        defaults: UserDefaults
    ) -> AppStorageIsolationPolicy {
        // The UI-test host has its own bundle identity, but volatile
        // per-launch preferences must land before any service reads defaults.
        UITestDefaults.installIfNeeded(
            arguments: arguments,
            environment: environment,
            defaults: defaults)
        return override ?? AppStorageIsolationPolicy(
            arguments: arguments,
            environment: environment)
    }
}
