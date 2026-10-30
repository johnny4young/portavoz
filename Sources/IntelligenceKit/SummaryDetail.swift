import Foundation

/// How much a summary keeps. Standard is the historical prompt, so its
/// fingerprints and cached snapshots stay valid.
public enum SummaryDetail: String, CaseIterable, Codable, Sendable {
    case brief
    case standard
    case detailed

    /// The extra instruction for the final pass; nil keeps the standard prompt.
    var summaryDirective: String? {
        switch self {
        case .brief:
            "Keep the summary brief: a two-sentence overview and at most three "
                + "bullets per section, only the points that matter most."
        case .standard:
            nil
        case .detailed:
            "Write a detailed summary: an overview of up to six sentences and up to "
                + "eight bullets per section, each carrying its concrete names, numbers, "
                + "dates, or owners. Never repeat a point or add anything the material "
                + "does not say."
        }
    }

    /// Bullets per map-phase note. Detailed notes stay several times smaller
    /// than their chunk so recursive condensing still converges.
    var noteBullets: Int { self == .detailed ? 14 : 10 }
    var noteTokens: Int { self == .detailed ? 350 : 250 }
}
