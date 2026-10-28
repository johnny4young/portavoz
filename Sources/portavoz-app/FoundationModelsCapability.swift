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
        guard let reason = FoundationModelSummaryProvider.unavailabilityReason(arguments: arguments) else {
            return .available
        }
        return .unavailable(localized(reason))
    }

    /// The provider reports English reasons; presentation embeds them in localized sentences.
    static func localized(_ reason: String) -> String {
        switch reason {
        case FoundationModelSummaryProvider.deviceNotEligibleReason:
            L10n.text("this device does not support Apple Intelligence")
        case FoundationModelSummaryProvider.appleIntelligenceDisabledReason:
            L10n.text("Apple Intelligence is turned off (System Settings → Apple Intelligence & Siri)")
        case FoundationModelSummaryProvider.modelNotReadyReason:
            L10n.text("the on-device model is still downloading; try again in a few minutes")
        default:
            reason
        }
    }
}
