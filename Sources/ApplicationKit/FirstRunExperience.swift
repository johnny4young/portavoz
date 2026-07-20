/// The minimum library fact needed to decide whether first-run guidance is
/// useful. Implementations expose no meeting content or persistence records.
public protocol FirstRunLibraryReading: Sendable {
    func containsMeetings() async throws -> Bool
}

/// Resolves whether the welcome experience should appear without making model
/// readiness, permissions, or audio capture part of launch eligibility.
public struct ResolveFirstRunExperience: ApplicationUseCase {
    public struct Request: Equatable, Sendable {
        public let forcePresentation: Bool
        public let suppressForDisposableStore: Bool
        public let hasCompleted: Bool

        public init(
            forcePresentation: Bool,
            suppressForDisposableStore: Bool,
            hasCompleted: Bool
        ) {
            self.forcePresentation = forcePresentation
            self.suppressForDisposableStore = suppressForDisposableStore
            self.hasCompleted = hasCompleted
        }
    }

    public struct Resolution: Equatable, Sendable {
        public let shouldPresent: Bool
        public let shouldMarkCompleted: Bool

        public init(shouldPresent: Bool, shouldMarkCompleted: Bool) {
            self.shouldPresent = shouldPresent
            self.shouldMarkCompleted = shouldMarkCompleted
        }
    }

    private let library: any FirstRunLibraryReading

    public init(library: any FirstRunLibraryReading) {
        self.library = library
    }

    public func execute(_ request: Request) async throws -> Resolution {
        let hasExistingMeetings: Bool
        do {
            hasExistingMeetings = request.forcePresentation
                || request.suppressForDisposableStore
                || request.hasCompleted
                ? false
                : try await library.containsMeetings()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A failed eligibility read must not silently suppress setup.
            return Resolution(shouldPresent: true, shouldMarkCompleted: false)
        }
        switch FirstRunOnboardingPolicy.decide(FirstRunOnboardingContext(
            forceRequested: request.forcePresentation,
            automationSuppressed: request.suppressForDisposableStore,
            hasCompleted: request.hasCompleted,
            hasExistingMeetings: hasExistingMeetings
        )) {
        case .show:
            return Resolution(shouldPresent: true, shouldMarkCompleted: false)
        case .hide:
            return Resolution(shouldPresent: false, shouldMarkCompleted: false)
        case .hideAndRememberCompleted:
            return Resolution(shouldPresent: false, shouldMarkCompleted: true)
        }
    }
}
