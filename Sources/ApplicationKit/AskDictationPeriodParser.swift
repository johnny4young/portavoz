import Foundation

/// Bilingual periods anchored to the local calendar. A named unit ("last week",
/// "la semana pasada") covers that whole unit; a span counted back from now
/// ("a week ago", "hace una semana", "the past 3 days") reaches until now, and
/// "since" / "desde" stretches any period until now.
struct AskDictationPeriodParser {
    let now: Date
    let calendar: Calendar

    struct Match {
        let interval: DateInterval
        let tokens: Range<Int>
    }

    /// The first period in the question.
    func find(in tokens: [String]) -> Match? {
        for start in tokens.indices {
            if let match = since(tokens, at: start) ?? period(tokens, at: start) { return match }
        }
        return nil
    }

    private func period(_ tokens: [String], at start: Int, bareWeekday: Bool = false) -> Match? {
        guard start < tokens.count else { return nil }
        return recent(tokens, at: start) ?? ago(tokens, at: start) ?? named(tokens, at: start)
            ?? date(tokens, at: start) ?? weekday(tokens, at: start, bare: bareWeekday)
    }

    /// "desde el lunes", "desde hace una semana", "since Monday", "since October 20".
    private func since(_ tokens: [String], at start: Int) -> Match? {
        guard ["desde", "since"].contains(tokens[start]) else { return nil }
        let skipsArticle = start + 1 < tokens.count && ["el", "la", "the"].contains(tokens[start + 1])
        let inner = period(tokens, at: start + 1, bareWeekday: true)
            ?? (skipsArticle ? period(tokens, at: start + 2, bareWeekday: true) : nil)
        guard let inner, inner.interval.start < now else { return nil }
        return Match(
            interval: DateInterval(start: inner.interval.start, end: now), tokens: start..<inner.tokens.upperBound)
    }

    /// "the past week", "in the last few days", "the last 3 days" and the Spanish
    /// "ultimos/ultima" forms. A bare "last week" is the previous calendar week instead.
    private func recent(_ tokens: [String], at start: Int) -> Match? {
        guard PeriodWords.recentLeads.contains(tokens[start]) else { return nil }
        let quantity = Self.quantity(tokens, at: start + 1)
        if tokens[start] == "last", quantity == nil, !(start > 0 && tokens[start - 1] == "the") { return nil }
        let unitIndex = start + 1 + (quantity?.length ?? 0)
        guard unitIndex < tokens.count, let unit = PeriodWords.units[tokens[unitIndex]] else { return nil }
        let count = quantity?.value ?? (unit.plural ? PeriodWords.few : 1)
        return rolling(count, unit.component, tokens: start..<(unitIndex + 1))
    }

    /// "a week ago", "a couple of days ago", or "hace" before the count, which may be omitted
    /// before a plural unit ("hace dias").
    private func ago(_ tokens: [String], at start: Int) -> Match? {
        let spanish = tokens[start] == "hace"
        let quantityStart = spanish ? start + 1 : start
        let quantity = Self.quantity(tokens, at: quantityStart)
        guard quantity != nil || spanish else { return nil }
        let unitIndex = quantityStart + (quantity?.length ?? 0)
        guard unitIndex < tokens.count, let unit = PeriodWords.units[tokens[unitIndex]],
              quantity != nil || unit.plural,
              spanish || tokens.matches(["ago"], at: unitIndex + 1)
        else { return nil }
        let end = unitIndex + (spanish ? 1 : 2)
        return rolling(quantity?.value ?? PeriodWords.few, unit.component, tokens: start..<end)
    }

    /// From the start of the day `count` units back (or that exact moment for hours) until now.
    private func rolling(_ count: Int, _ unit: Calendar.Component, tokens: Range<Int>) -> Match? {
        guard let then = calendar.date(byAdding: unit, value: -count, to: now) else { return nil }
        let start = unit == .hour ? then : calendar.startOfDay(for: then)
        return Match(interval: DateInterval(start: start, end: now), tokens: tokens)
    }

    static func quantity(_ tokens: [String], at index: Int) -> (value: Int, length: Int)? {
        guard index < tokens.count else { return nil }
        for (words, value) in PeriodWords.quantityPhrases where tokens.matches(words, at: index) {
            return (value, words.count)
        }
        guard let value = Int(tokens[index]) ?? PeriodWords.numbers[tokens[index]], (1...999).contains(value)
        else { return nil }
        return (value, 1)
    }
}

extension AskDictationPeriodParser {
    enum Named {
        case day(Int)
        case unit(Calendar.Component, Int)
        case hours(from: Int, until: Int)
        case weekend(previous: Bool)
        case lastDays(Int)
    }

    /// Fixed phrases, longest first so "ayer por la noche" wins over "ayer".
    private func named(_ tokens: [String], at start: Int) -> Match? {
        for (words, kind) in PeriodWords.phrases where tokens.matches(words, at: start) {
            return interval(for: kind).map { Match(interval: $0, tokens: start..<(start + words.count)) }
        }
        return nil
    }

    private func interval(for kind: Named) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        switch kind {
        case .day(let offset):
            return calendar.date(byAdding: .day, value: offset, to: today)
                .flatMap { calendar.dateInterval(of: .day, for: $0) }
        case .unit(let unit, let offset):
            return calendar.date(byAdding: unit, value: offset, to: now)
                .flatMap { calendar.dateInterval(of: unit, for: $0) }
        case .hours(let from, let until):
            guard let start = calendar.date(byAdding: .hour, value: from, to: today),
                  let end = calendar.date(byAdding: .hour, value: until, to: today)
            else { return nil }
            return DateInterval(start: start, end: end)
        case .weekend(let previous):
            // Days back to Saturday (weekday 7): 0 on Saturday, 1 on Sunday, so on a
            // weekend day "this weekend" is the current one.
            var back = calendar.component(.weekday, from: today) % 7
            if previous, back <= 1 { back += 7 }
            guard let saturday = calendar.date(byAdding: .day, value: -back, to: today),
                  let monday = calendar.date(byAdding: .day, value: 2, to: saturday)
            else { return nil }
            return DateInterval(start: saturday, end: monday)
        case .lastDays(let days):
            return rolling(days, .day, tokens: 0..<0)?.interval
        }
    }

    /// "el lunes", "del martes", "on Monday", "el viernes pasado", "last Friday"; the most
    /// recent such day, today included unless "pasado"/"last" says otherwise. A weekday
    /// after "sobre"/"about" is the topic, not a period.
    private func weekday(_ tokens: [String], at start: Int, bare: Bool) -> Match? {
        let hasLead = PeriodWords.weekdayLeads.contains(tokens[start])
        let dayIndex = hasLead ? start + 1 : start
        guard hasLead || bare, dayIndex < tokens.count,
              let weekday = PeriodWords.weekdays[tokens[dayIndex]],
              !(start > 0 && PeriodWords.topicMarkers.contains(tokens[start - 1]))
        else { return nil }
        var end = dayIndex + 1
        var excludesToday = tokens[start] == "last"
        if tokens.matches(["pasado"], at: end) {
            excludesToday = true
            end += 1
        }
        let today = calendar.startOfDay(for: now)
        var back = (calendar.component(.weekday, from: today) - weekday + 7) % 7
        if back == 0, excludesToday { back = 7 }
        return calendar.date(byAdding: .day, value: -back, to: today)
            .flatMap { calendar.dateInterval(of: .day, for: $0) }
            .map { Match(interval: $0, tokens: start..<end) }
    }

    /// "21 de octubre", "October 21", "21 October 2026", "2026 10 21"; without a
    /// year, a date still to come this year means last year's.
    private func date(_ tokens: [String], at start: Int) -> Match? {
        func number(_ index: Int) -> Int? { index < tokens.count ? Int(tokens[index].trimmingOrdinal) : nil }
        func month(_ index: Int) -> Int? { index < tokens.count ? PeriodWords.months[tokens[index]] : nil }
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
}

/// Accent-free, lowercased vocabulary for `AskDictationPeriodParser`.
enum PeriodWords {
    /// "a few days", "several weeks" and their Spanish forms: a small count.
    static let few = 3

    static let phrases: [([String], AskDictationPeriodParser.Named)] = {
        let entries: [([String], AskDictationPeriodParser.Named)] = [
            (["hoy"], .day(0)), (["today"], .day(0)),
            (["ayer"], .day(-1)), (["yesterday"], .day(-1)),
            (["anteayer"], .day(-2)), (["antier"], .day(-2)), (["antes", "de", "ayer"], .day(-2)),
            (["day", "before", "yesterday"], .day(-2)),
            (["esta", "semana"], .unit(.weekOfYear, 0)), (["this", "week"], .unit(.weekOfYear, 0)),
            (["semana", "pasada"], .unit(.weekOfYear, -1)), (["semana", "anterior"], .unit(.weekOfYear, -1)),
            (["last", "week"], .unit(.weekOfYear, -1)), (["previous", "week"], .unit(.weekOfYear, -1)),
            (["este", "mes"], .unit(.month, 0)), (["this", "month"], .unit(.month, 0)),
            (["mes", "pasado"], .unit(.month, -1)), (["mes", "anterior"], .unit(.month, -1)),
            (["last", "month"], .unit(.month, -1)), (["previous", "month"], .unit(.month, -1)),
            (["este", "ano"], .unit(.year, 0)), (["this", "year"], .unit(.year, 0)),
            (["ano", "pasado"], .unit(.year, -1)), (["ano", "anterior"], .unit(.year, -1)),
            (["last", "year"], .unit(.year, -1)), (["previous", "year"], .unit(.year, -1)),
            (["esta", "manana"], .hours(from: 0, until: 12)), (["this", "morning"], .hours(from: 0, until: 12)),
            (["esta", "tarde"], .hours(from: 12, until: 19)), (["this", "afternoon"], .hours(from: 12, until: 19)),
            (["esta", "noche"], .hours(from: 18, until: 24)), (["tonight"], .hours(from: 18, until: 24)),
            (["this", "evening"], .hours(from: 18, until: 24)),
            (["anoche"], .hours(from: -6, until: 6)), (["last", "night"], .hours(from: -6, until: 6)),
            (["ayer", "en", "la", "noche"], .hours(from: -6, until: 6)),
            (["ayer", "por", "la", "noche"], .hours(from: -6, until: 6)),
            (["fin", "de", "semana", "pasado"], .weekend(previous: true)),
            (["last", "weekend"], .weekend(previous: true)),
            (["fin", "de", "semana"], .weekend(previous: false)), (["weekend"], .weekend(previous: false)),
            (["hace", "poco"], .lastDays(7)), (["recientemente"], .lastDays(7)), (["ultimamente"], .lastDays(7)),
            (["recently"], .lastDays(7)), (["lately"], .lastDays(7))
        ]
        return entries.sorted { $0.0.count > $1.0.count }
    }()

    static let units: [String: (component: Calendar.Component, plural: Bool)] = [
        "dia": (.day, false), "dias": (.day, true), "day": (.day, false), "days": (.day, true),
        "semana": (.weekOfYear, false), "semanas": (.weekOfYear, true),
        "week": (.weekOfYear, false), "weeks": (.weekOfYear, true),
        "mes": (.month, false), "meses": (.month, true), "month": (.month, false), "months": (.month, true),
        "ano": (.year, false), "anos": (.year, true), "year": (.year, false), "years": (.year, true),
        "hora": (.hour, false), "horas": (.hour, true), "hour": (.hour, false), "hours": (.hour, true)
    ]

    static let recentLeads: Set<String> = ["ultimo", "ultima", "ultimos", "ultimas", "past", "last"]

    static let quantityPhrases: [([String], Int)] = [
        (["un", "par", "de"], 2), (["a", "couple", "of"], 2), (["unos", "pocos"], few), (["unas", "pocas"], few),
        (["par", "de"], 2), (["a", "couple"], 2), (["couple", "of"], 2), (["a", "few"], few),
        (["unos"], few), (["unas"], few), (["algunos"], few), (["algunas"], few), (["varios"], few),
        (["varias"], few), (["few"], few), (["several"], few), (["some"], few)
    ]

    static let numbers: [String: Int] = [
        "un": 1, "uno": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7,
        "ocho": 8, "nueve": 9, "diez": 10, "once": 11, "doce": 12, "quince": 15, "veinte": 20, "treinta": 30,
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30
    ]

    static let weekdays: [String: Int] = [
        "domingo": 1, "lunes": 2, "martes": 3, "miercoles": 4, "jueves": 5, "viernes": 6, "sabado": 7,
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7
    ]

    static let weekdayLeads: Set<String> = ["el", "del", "on", "last", "este", "this"]

    /// Words that make a following weekday a topic ("sobre el viernes"), not a period.
    static let topicMarkers: Set<String> = ["sobre", "acerca", "para", "hasta", "de", "del", "about", "until", "by"]

    static let months: [String: Int] = [
        "enero": 1, "febrero": 2, "marzo": 3, "abril": 4, "mayo": 5, "junio": 6, "julio": 7, "agosto": 8,
        "septiembre": 9, "setiembre": 9, "octubre": 10, "noviembre": 11, "diciembre": 12,
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7,
        "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9,
        "oct": 10, "nov": 11, "dec": 12
    ]
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
