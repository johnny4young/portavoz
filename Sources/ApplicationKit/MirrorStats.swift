import Foundation

/// The post-meeting mirror (6a-2): the user's own numbers next to their
/// personal average — "measured, not judged". Pure so the synthesis line
/// is deterministic and testable; the copy NEVER uses evaluative adjectives
/// (no "too much", "bad"), only facts and a factual comparison.
public enum MirrorStats {
    /// A meeting qualifies for the mirror only when it's a real conversation
    /// (≥ 2 attributed speakers) that ran long enough to reflect on.
    public static let minSpeakers = 2
    public static let minSeconds: TimeInterval = 300
    /// The user's share must differ from their average by more than this to
    /// be worth calling out (in amber).
    public static let notableDelta = 0.10

    public static func qualifies(speakerCount: Int, seconds: TimeInterval) -> Bool {
        speakerCount >= minSpeakers && seconds >= minSeconds
    }

    /// Whether the user's share this meeting is notably different from their
    /// average — drives the amber highlight on the "% you spoke" tile.
    public static func isNotable(myShare: Double, average: Double) -> Bool {
        abs(myShare - average) > notableDelta
    }

    /// The one-line factual synthesis. `average` is nil when there isn't
    /// enough history to compare — then it just states this meeting's facts.
    public static func synthesis(
        myShare: Double, average: Double?, questions: Int, language: String
    ) -> String {
        let spanish = language.hasPrefix("es")
        // Talk-balance clause, compared to the user's own usual share.
        let balance: String
        if let average, abs(myShare - average) > notableDelta {
            if myShare < average {
                balance = spanish
                    ? "Escuchaste más de lo habitual."
                    : "You listened more than usual."
            } else {
                balance = spanish
                    ? "Hablaste más de lo habitual."
                    : "You spoke more than usual."
            }
        } else {
            balance = spanish
                ? "Tu balance de habla estuvo cerca de tu media."
                : "Your talk balance was close to your usual."
        }
        // Questions clause — a fact, not a verdict.
        let questionClause: String
        switch questions {
        case 0:
            questionClause = spanish ? "No hiciste preguntas." : "You asked no questions."
        case 1:
            questionClause = spanish ? "Hiciste 1 pregunta." : "You asked 1 question."
        default:
            questionClause = spanish
                ? "Hiciste \(questions) preguntas."
                : "You asked \(questions) questions."
        }
        return "\(balance) \(questionClause)"
    }
}
