import DictationOwnership
import Foundation
import OSLog

/// A Mac where 1.x Portavoz was the last dictation owner still records it; 2.0 frees that once per
/// launch so Secreteo can take it. Nothing here claims, and only the shipping build touches the
/// shared state: Dev builds and disposable libraries never do.
enum LegacyDictationOwnershipRelease {
    static let shippingIdentifier = "app.portavoz.mac"
    private static let logger = Logger(subsystem: "app.portavoz.mac", category: "legacy-dictation")

    static func applies(identifier: String?, usesTemporaryStore: Bool) -> Bool {
        !usesTemporaryStore && identifier == shippingIdentifier
    }

    /// Off the main actor; a busy or failed release is logged and retried at the next launch.
    static func startIfNeeded(identifier: String? = Bundle.main.bundleIdentifier, usesTemporaryStore: Bool) {
        guard applies(identifier: identifier, usesTemporaryStore: usesTemporaryStore) else { return }
        Task.detached(priority: .utility) {
            await relinquish(DictationOwnership(participant: shippingIdentifier, conditions: {
                ParticipantConditions(preferenceIsOn: false, missingForReadiness: nil, legacyPeerIsActive: false)
            }))
        }
    }

    @discardableResult
    static func relinquish(_ ownership: DictationOwnership) async -> OwnershipChange {
        let change = await ownership.relinquishForRemoval()
        if change == .busy || change == .failed {
            logger.error("legacy dictation ownership release: \(String(describing: change), privacy: .public)")
        }
        return change
    }
}
