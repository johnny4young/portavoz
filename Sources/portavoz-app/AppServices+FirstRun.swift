import ApplicationKit
import Foundation
import StorageKit

struct AppFirstRunLibraryReader: FirstRunLibraryReading {
    let store: MeetingStore

    func containsMeetings() async throws -> Bool {
        try await store.liveMeetingCount() > 0
    }
}

@MainActor
final class AppFirstRunModelClient: FirstRunModelClient {
    private let useCase: ResolveFirstRunExperience
    private let defaults: UserDefaults
    private let arguments: [String]

    init(
        useCase: ResolveFirstRunExperience,
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.useCase = useCase
        self.defaults = defaults
        self.arguments = arguments
    }

    func resolveFirstRun() async throws -> ResolveFirstRunExperience.Resolution {
        try await useCase.execute(.init(
            forcePresentation: arguments.contains("-show-onboarding"),
            suppressForDisposableStore: arguments.contains("-use-temp-store"),
            hasCompleted: defaults.bool(forKey: "hasOnboarded")))
    }

    func markFirstRunCompleted() {
        defaults.set(true, forKey: "hasOnboarded")
    }
}
