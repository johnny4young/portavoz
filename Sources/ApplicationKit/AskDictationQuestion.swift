import Foundation
import PortavozCore

/// What a question about dictations asks for besides words: a period, an app,
/// and the words left to search. Parsing is deterministic, bilingual and local.
public struct AskDictationQuestion: Equatable, Sendable {
    public let period: DateInterval?
    public let applicationName: String?
    public let searchWords: [String]
    /// "resume", "summarize": the answer should summarize, not only list.
    public let asksForSummary: Bool

    /// Nothing left to search: the newest dictations within the filters answer it.
    public var isListing: Bool { searchWords.isEmpty }

    public init(period: DateInterval?, applicationName: String?, searchWords: [String], asksForSummary: Bool = false) {
        self.period = period
        self.applicationName = applicationName
        self.searchWords = searchWords
        self.asksForSummary = asksForSummary
    }

    public static func parse(
        _ question: String,
        applications: [String],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Self {
        let tokens = BilingualFunctionWords.foldedTokens(in: question)
        var consumed = Set<Int>()
        let period = AskDictationPeriodParser(now: now, calendar: calendar).find(in: tokens)
        if let period { consumed.formUnion(period.tokens) }
        let application = Self.application(in: tokens, consumed: consumed, applications: applications)
        if let application { consumed.formUnion(application.tokens) }
        let words = tokens.indices
            .filter { !consumed.contains($0) }
            .map { tokens[$0] }
            .filter { $0.count > 1 || $0.allSatisfy(\.isNumber) }
            .filter { !BilingualFunctionWords.all.contains($0) && !Self.requestWords.contains($0) }
        return Self(
            period: period?.interval, applicationName: application?.name, searchWords: words,
            asksForSummary: tokens.contains(where: summaryWords.contains))
    }

    /// The longest saved app name introduced by a preposition ("en Slack", "in Mail").
    private static func application(
        in tokens: [String], consumed: Set<Int>, applications: [String]
    ) -> (name: String, tokens: Range<Int>)? {
        var best: (name: String, tokens: Range<Int>)?
        for name in applications {
            let target = BilingualFunctionWords.foldedTokens(in: name)
            guard !target.isEmpty, target.count < tokens.count else { continue }
            for start in 1...(tokens.count - target.count)
            where Array(tokens[start..<(start + target.count)]) == target {
                let span = (start - 1)..<(start + target.count)
                guard applicationPrepositions.contains(tokens[start - 1]),
                      !span.contains(where: consumed.contains),
                      span.count > (best?.tokens.count ?? 0)
                else { continue }
                best = (name, span)
            }
        }
        return best
    }

    private static let summaryWords: Set<String> = [
        "resume", "resumen", "resumeme", "resumir", "resumelos", "summarize", "summary", "recap"
    ]

    private static let applicationPrepositions: Set<String> = [
        "en", "de", "del", "desde", "a", "para", "in", "on", "from", "to", "into"
    ]

    /// Words that ask for dictations rather than describe their content.
    static let requestWords: Set<String> = [
        "dame", "damelos", "muestrame", "muestra", "mostrar", "ensename", "lista", "listame", "listar",
        "busca", "buscame", "buscar", "encuentra", "dime", "quiero", "ver", "todo", "todos", "todas",
        "mis", "mi", "cuales", "cuantos", "cuantas", "dicte", "dictaste", "dicto", "dictado", "dictados",
        "dictacion", "dictaciones", "dije", "dijiste", "hable", "escribi", "sobre", "acerca", "hice",
        "tengo", "hay", "puedes", "podrias", "favor", "resume", "resumen", "resumeme", "resumir", "resumelos",
        "hace", "ago", "recap", "desde", "since", "durante", "during", "recent", "recently", "lately", "over",
        "reciente", "recientes", "recientemente", "ultimamente",
        "show", "me", "give", "list", "find", "search", "tell", "all", "my", "dictate", "dictated",
        "dictation", "dictations", "say", "said", "wrote", "write", "about", "please", "any", "have",
        "there", "were", "was", "everything", "summarize", "summary"
    ]
}
