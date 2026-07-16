import ApplicationKit
import Foundation
import IntelligenceKit

/// One app-owned interpretation of Apple's Foundation Models capability.
/// Presentation, provider composition, and test fixtures consume this value
/// instead of each re-implementing an OS/version check.
enum FoundationModelsCapability: Equatable, Sendable {
    case available
    case requiresMacOS26
    case unavailable(String)

    var isAvailable: Bool {
        self == .available
    }

    /// A clean install must never default to an engine that cannot exist on
    /// this OS. MLX may still need its explicit verified download, which has
    /// an actionable Settings state rather than an impossible Apple call.
    var defaultSummaryEngine: SummaryEngine {
        isAvailable ? .appleOnDevice : .mlx
    }

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> FoundationModelsCapability {
        // Deterministic XCUITest coverage for the supported Sequoia floor,
        // independent of the host Mac running the test suite.
        if arguments.contains("-simulate-sequoia-capabilities") {
            return .requiresMacOS26
        }
        guard #available(macOS 26.0, *) else {
            return .requiresMacOS26
        }
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            return .unavailable(reason)
        }
        return .available
    }
}
