import Foundation

/// How much a summary keeps. Standard is the historical prompt, so its
/// fingerprints and cached snapshots stay valid.
public enum SummaryDetail: String, CaseIterable, Codable, Sendable {
    case brief
    case standard
    case detailed

    /// The extra instruction for the final pass; nil keeps the standard prompt.
    /// Counted or "keep everything" phrasing sent the embedded 4B model into
    /// repetition loops; naming the scope and asking it to stop does not.
    var summaryDirective: String? {
        switch self {
        case .brief:
            "Write a short summary: only the points that matter most, in as few "
                + "bullets as possible. Never repeat a point, and stop once those "
                + "points are covered."
        case .standard:
            nil
        case .detailed:
            "Write a fuller summary than usual: cover every topic the meeting "
                + "discussed, one short bullet per distinct point. Never repeat a point, "
                + "and stop once the material is covered."
        }
    }

    /// Bullets per map-phase note. Detailed notes stay several times smaller
    /// than their chunk so recursive condensing still converges.
    var noteBullets: Int { self == .detailed ? 14 : 10 }
    var noteTokens: Int { self == .detailed ? 350 : 250 }
}
