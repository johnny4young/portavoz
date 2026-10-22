import ApplicationKit
import Foundation

enum AskAnswerPresentation {
    static func text(for result: AskMeetingAnswer) -> String {
        guard !result.citations.isEmpty else {
            return L10n.text("Nothing related in your meetings yet.")
        }
        return result.generatedText
            ?? L10n.text("Closest passages from your meetings:")
    }

    static func statusText(
        for outcome: AskGenerationOutcome,
        hasCitations: Bool
    ) -> String? {
        guard hasCitations else { return nil }
        switch outcome {
        case .notRequested, .generated:
            return nil
        case .insufficientEvidence:
            return L10n.text(
                "The sources do not support an answer. Exact matches are still shown.")
        case .unavailable:
            return L10n.text(
                "Your selected local answer engine is unavailable. Exact passages are still shown.")
        case .failed:
            return L10n.text(
                "Your selected local answer engine could not finish. Exact passages are still shown.")
        case .timedOut:
            return L10n.text(
                "Your selected local answer engine took too long. Exact passages are still shown.")
        }
    }

    static func text(for result: AskWebAnswer) -> String {
        guard !result.citations.isEmpty else {
            return L10n.text("Nothing readable was found at that page.")
        }
        return result.generatedText
            ?? L10n.text("Closest passages from the selected web source:")
    }

    static func text(for result: AskNoteAnswer) -> String {
        guard !result.citations.isEmpty else {
            return L10n.text("Nothing related in your notes yet.")
        }
        return result.generatedText
            ?? L10n.text("Closest raw notes:")
    }

    static func text(
        for result: AskDictationAnswer,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if result.historyIsOff {
            return L10n.text("Dictation history is off, so nothing was searched.")
        }
        if let listing = result.listing {
            if let generated = result.generatedText { return generated }
            let scope = dictationScope(listing, now: now, calendar: calendar)
            if result.citations.isEmpty {
                return scope.map { L10n.format("You have no saved dictations %@.", $0) }
                    ?? L10n.text("You have no saved dictations yet.")
            }
            return scope.map { L10n.format("Your dictations %@:", $0) }
                ?? L10n.text("Your most recent dictations:")
        }
        guard !result.citations.isEmpty else {
            return L10n.text("No saved dictation mentions that.")
        }
        return result.generatedText
            ?? L10n.text("Closest dictations:")
    }

    /// "in Slack from yesterday", "between October 19 and October 25"; nil when unfiltered.
    static func dictationScope(_ listing: AskDictationScope, now: Date, calendar: Calendar) -> String? {
        let locale = AppLanguage.current.locale
        var parts: [String] = []
        if let application = listing.applicationName {
            parts.append(L10n.format("in %@", application))
        }
        if let period = listing.period {
            let lastMoment = period.end.addingTimeInterval(-1)
            let longDate = Date.FormatStyle(date: .long, time: .omitted, locale: locale)
            if period.start != calendar.startOfDay(for: period.start) {
                let time = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
                parts.append(L10n.format("since %@", period.start.formatted(time)))
            } else if !calendar.isDate(period.start, inSameDayAs: lastMoment) {
                parts.append(L10n.format(
                    "between %@ and %@", period.start.formatted(longDate), lastMoment.formatted(longDate)))
            } else if calendar.isDate(period.start, inSameDayAs: now) {
                parts.append(L10n.text("from today"))
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(period.start, inSameDayAs: yesterday) {
                parts.append(L10n.text("from yesterday"))
            } else {
                parts.append(L10n.format("from %@", period.start.formatted(longDate)))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
