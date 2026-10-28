import ApplicationKit
import Foundation
import IntelligenceKit

/// One app-owned interpretation of Apple's Foundation Models capability.
/// Presentation, provider composition, and test fixtures consume this value
/// instead of each re-implementing an availability check.
enum FoundationModelsCapability: Equatable, Sendable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        self == .available
    }

    /// A clean install must never default to an engine that cannot run on
    /// this Mac. MLX may still need its explicit verified download, which has
    /// an actionable Settings state rather than an impossible Apple call.
    var defaultSummaryEngine: SummaryEngine {
        isAvailable ? .appleOnDevice : .mlx
    }

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> FoundationModelsCapability {
        // Deterministic XCUITest coverage for a Mac without Apple
        // Intelligence, independent of the host running the test suite.
        if arguments.contains("-simulate-no-apple-intelligence") {
            return .unavailable(FoundationModelSummaryProvider.appleIntelligenceDisabledReason)
        }
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            return .unavailable(reason)
        }
        return .available
    }
}
