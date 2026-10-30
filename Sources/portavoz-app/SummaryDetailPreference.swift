import Foundation
import IntelligenceKit

/// The detail level new summaries use unless Regenerate picks another one.
enum SummaryDetailPreference {
    static let key = "summaryDetail"

    static func current(_ defaults: UserDefaults = .standard) -> SummaryDetail {
        defaults.string(forKey: key).flatMap(SummaryDetail.init(rawValue:)) ?? .standard
    }
}

extension SummaryDetail {
    var title: String {
        switch self {
        case .brief: L10n.text("Concise")
        case .standard: L10n.text("Standard")
        case .detailed: L10n.text("Detailed")
        }
    }
}
