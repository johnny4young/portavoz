import Foundation
import PortavozCore

/// Who can see a record. Defaults to `.private`; reserved from v1 so the
/// sharing roadmap (share sheet → CKShare → self-hostable relay) never
/// forces a schema migration. CloudKit sync via CKSyncEngine arrives with
/// the iOS companion milestone.
public enum Visibility: String, Codable, Sendable {
    case `private`
    case shared
}
