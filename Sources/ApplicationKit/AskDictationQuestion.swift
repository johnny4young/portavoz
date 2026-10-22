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
        "hace", "ago", "recap",
        "show", "me", "give", "list", "find", "search", "tell", "all", "my", "dictate", "dictated",
        "dictation", "dictations", "say", "said", "wrote", "write", "about", "please", "any", "have",
        "there", "were", "was", "everything", "summarize", "summary"
    ]
}

/// Bilingual periods anchored to the local calendar: relative days, weeks and
/// months, parts of today, the last N days or hours, weekdays and dates.
struct AskDictationPeriodParser {
    let now: Date
    let calendar: Calendar

    struct Match {
        let interval: DateInterval
        let tokens: Range<Int>
    }

    private enum Relative {
        case day(Int)
        case week(Int)
        case month(Int)
        case partOfToday(Int, Int)
    }

    private static let phrases: [([String], Relative)] = [
        (["antes", "de", "ayer"], .day(-2)), (["day", "before", "yesterday"], .day(-2)),
        (["la", "semana", "pasada"], .week(-1)), (["el", "mes", "pasado"], .month(-1)),
        (["semana", "pasada"], .week(-1)), (["last", "week"], .week(-1)),
        (["esta", "semana"], .week(0)), (["this", "week"], .week(0)),
        (["mes", "pasado"], .month(-1)), (["last", "month"], .month(-1)),
        (["este", "mes"], .month(0)), (["this", "month"], .month(0)),
        (["esta", "manana"], .partOfToday(0, 12)), (["this", "morning"], .partOfToday(0, 12)),
        (["esta", "tarde"], .partOfToday(12, 19)), (["this", "afternoon"], .partOfToday(12, 19)),
        (["anteayer"], .day(-2)), (["antier"], .day(-2)),
        (["hoy"], .day(0)), (["today"], .day(0)), (["ayer"], .day(-1)), (["yesterday"], .day(-1))
    ]

    private static let weekdays: [String: Int] = [
        "domingo": 1, "lunes": 2, "martes": 3, "miercoles": 4, "jueves": 5, "viernes": 6, "sabado": 7,
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7
    ]

    private static let months: [String: Int] = [
        "enero": 1, "febrero": 2, "marzo": 3, "abril": 4, "mayo": 5, "junio": 6, "julio": 7, "agosto": 8,
        "septiembre": 9, "setiembre": 9, "octubre": 10, "noviembre": 11, "diciembre": 12,
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7,
        "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9,
        "oct": 10, "nov": 11, "dec": 12
    ]

    private static let numberWords: [String: Int] = [
        "un": 1, "uno": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7,
        "ocho": 8, "nueve": 9, "diez": 10, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "an": 1
    ]

    /// Words that make a following weekday a topic ("sobre el viernes"), not a period.
    private static let topicMarkers: Set<String> = ["sobre", "acerca", "para", "hasta", "de", "del"]

    /// The first period in the question.
    func find(in tokens: [String]) -> Match? {
        for start in tokens.indices {
            if let match = relative(tokens, at: start) ?? lastSpan(tokens, at: start)
                ?? ago(tokens, at: start) ?? date(tokens, at: start) ?? weekday(tokens, at: start) {
                return match
            }
        }
        return nil
    }

    private func relative(_ tokens: [String], at start: Int) -> Match? {
        for (words, kind) in Self.phrases where tokens.matches(words, at: start) {
            guard let interval = interval(for: kind) else { return nil }
            return Match(interval: interval, tokens: start..<(start + words.count))
        }
        return nil
    }

    private func interval(for kind: Relative) -> DateInterval? {
        switch kind {
        case .day(let offset):
            return calendar.date(byAdding: .day, value: offset, to: now)
                .flatMap { calendar.dateInterval(of: .day, for: $0) }
        case .week(let offset):
            return calendar.date(byAdding: .weekOfYear, value: offset, to: now)
                .flatMap { calendar.dateInterval(of: .weekOfYear, for: $0) }
        case .month(let offset):
            return calendar.date(byAdding: .month, value: offset, to: now)
                .flatMap { calendar.dateInterval(of: .month, for: $0) }
        case .partOfToday(let from, let until):
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .hour, value: from, to: today),
                  let end = calendar.date(byAdding: .hour, value: until, to: today)
            else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    /// The last N days, hours or weeks ("last 2 hours", "past three weeks").
    private func lastSpan(_ tokens: [String], at start: Int) -> Match? {
        guard ["ultimos", "ultimas", "last", "past"].contains(tokens[start]),
              start + 2 < tokens.count,
              let count = Int(tokens[start + 1]) ?? Self.numberWords[tokens[start + 1]],
              (1...366).contains(count)
        else { return nil }
        let units: [String: Calendar.Component] = [
            "dias": .day, "days": .day, "horas": .hour, "hours": .hour, "semanas": .weekOfYear, "weeks": .weekOfYear
        ]
        guard let unit = units[tokens[start + 2]],
              let from = calendar.date(byAdding: unit, value: -count, to: now)
        else { return nil }
        return Match(interval: DateInterval(start: from, end: now), tokens: start..<(start + 3))
    }

    /// "3 days ago", "a week ago" (or "hace" before the count): that day or
    /// week; hours ago reach back from now.
    private func ago(_ tokens: [String], at start: Int) -> Match? {
        let spanish = tokens[start] == "hace"
        let countIndex = spanish ? start + 1 : start
        guard countIndex + 1 < tokens.count,
              let count = Int(tokens[countIndex]) ?? Self.numberWords[tokens[countIndex]]
                ?? (tokens[countIndex] == "a" ? 1 : nil),
              (1...366).contains(count),
              spanish || tokens.matches(["ago"], at: countIndex + 2)
        else { return nil }
        let end = spanish ? countIndex + 2 : countIndex + 3
        let match: (Calendar.Component, Calendar.Component)?
        switch tokens[countIndex + 1] {
        case "dia", "dias", "day", "days": match = (.day, .day)
        case "semana", "semanas", "week", "weeks": match = (.weekOfYear, .weekOfYear)
        case "hora", "horas", "hour", "hours": match = (.hour, .hour)
        default: match = nil
        }
        guard let (unit, span) = match,
              let then = calendar.date(byAdding: unit, value: -count, to: now)
        else { return nil }
        if unit == .hour { return Match(interval: DateInterval(start: then, end: now), tokens: start..<end) }
        return calendar.dateInterval(of: span, for: then).map { Match(interval: $0, tokens: start..<end) }
    }

    /// "21 de octubre", "October 21", "21 October 2026", "2026 10 21".
    private func date(_ tokens: [String], at start: Int) -> Match? {
        func number(_ index: Int) -> Int? { index < tokens.count ? Int(tokens[index].trimmingOrdinal) : nil }
        func month(_ index: Int) -> Int? { index < tokens.count ? Self.months[tokens[index]] : nil }
        if tokens[start].count == 4, let year = number(start), let month = number(start + 1),
           let day = number(start + 2) {
            return dayMatch(year: year, month: month, day: day, tokens: start..<(start + 3))
        }
        var parts: (day: Int, month: Int, end: Int)?
        if let day = number(start), tokens.matches(["de"], at: start + 1), let month = month(start + 2) {
            parts = (day, month, start + 3)
        } else if let day = number(start), let month = month(start + 1) {
            parts = (day, month, start + 2)
        } else if let month = month(start), let day = number(start + 1) {
            parts = (day, month, start + 2)
        }
        guard let parts else { return nil }
        var end = parts.end
        var year: Int?
        if tokens.matches(["de"], at: end), let value = number(end + 1), value > 1900 {
            (year, end) = (value, end + 2)
        } else if let value = number(end), value > 1900 {
            (year, end) = (value, end + 1)
        }
        return dayMatch(year: year, month: parts.month, day: parts.day, tokens: start..<end)
    }

    private func dayMatch(year: Int?, month: Int, day: Int, tokens: Range<Int>) -> Match? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let currentYear = calendar.component(.year, from: now)
        var components = DateComponents(year: year ?? currentYear, month: month, day: day)
        guard var date = calendar.date(from: components), calendar.component(.day, from: date) == day
        else { return nil }
        if year == nil, date > now {
            components.year = currentYear - 1
            guard let lastYear = calendar.date(from: components) else { return nil }
            date = lastYear
        }
        return calendar.dateInterval(of: .day, for: date).map { Match(interval: $0, tokens: tokens) }
    }

    /// "el lunes", "del martes", "on Monday", "el viernes pasado", "last Friday"; the most
    /// recent such day, today included unless "pasado"/"last" says otherwise.
    private func weekday(_ tokens: [String], at start: Int) -> Match? {
        guard ["el", "del", "on", "last", "este", "this"].contains(tokens[start]),
              start + 1 < tokens.count,
              let weekday = Self.weekdays[tokens[start + 1]],
              !(start > 0 && Self.topicMarkers.contains(tokens[start - 1]))
        else { return nil }
        var end = start + 2
        var excludesToday = tokens[start] == "last"
        if tokens.matches(["pasado"], at: end) {
            excludesToday = true
            end += 1
        }
        let today = calendar.startOfDay(for: now)
        let todayWeekday = calendar.component(.weekday, from: today)
        var back = (todayWeekday - weekday + 7) % 7
        if back == 0, excludesToday { back = 7 }
        return calendar.date(byAdding: .day, value: -back, to: today)
            .flatMap { calendar.dateInterval(of: .day, for: $0) }
            .map { Match(interval: $0, tokens: start..<end) }
    }
}

private extension Array where Element == String {
    func matches(_ words: [String], at start: Int) -> Bool {
        start >= 0 && start + words.count <= count && Array(self[start..<(start + words.count)]) == words
    }
}

private extension String {
    /// "21st" → "21"; other text is unchanged.
    var trimmingOrdinal: String {
        for suffix in ["st", "nd", "rd", "th"] where hasSuffix(suffix) && dropLast(2).allSatisfy(\.isNumber) {
            return String(dropLast(2))
        }
        return self
    }
}
