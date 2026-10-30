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
            "Write a detailed summary: a full overview paragraph, then every distinct "
                + "topic, decision, number, date, and open question as its own bullet, "
                + "attributed to its speaker label. Prefer completeness over brevity, "
                + "but never add anything the material does not say."
        }
    }

    /// Bullets per map-phase note. Detailed notes stay several times smaller
    /// than their chunk so recursive condensing still converges.
    var noteBullets: Int { self == .detailed ? 14 : 10 }
    var noteTokens: Int { self == .detailed ? 350 : 250 }
}
