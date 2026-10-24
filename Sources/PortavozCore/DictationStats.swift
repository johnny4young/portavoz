import Foundation

/// One finished dictation as the statistics see it: counts and time, never text.
public struct DictationStatsSample: Equatable, Sendable {
    public let id: DictationRecordID
    /// The local calendar day it started, `yyyy-MM-dd`.
    public let day: String
    public let words: Int
    public let spokenDuration: TimeInterval
    public let applicationName: String?
    public let delivered: Bool

    public init(
        id: DictationRecordID, day: String, words: Int, spokenDuration: TimeInterval,
        applicationName: String?, delivered: Bool
    ) {
        self.id = id
        self.day = day
        self.words = words
        self.spokenDuration = spokenDuration
        self.applicationName = applicationName
        self.delivered = delivered
    }

    public var isValid: Bool {
        DictationStatsCalendar.isDay(day) && words >= 0 && spokenDuration.isFinite && spokenDuration >= 0
            && (applicationName?.unicodeScalars.count ?? 0) <= DictationRecord.maximumLabelLength
    }
}

/// Totals for one day, or for a range when summed.
public struct DictationStatsTotals: Equatable, Sendable {
    public var dictations: Int
    public var words: Int
    public var spokenDuration: TimeInterval
    public var notDelivered: Int

    public static let zero = Self(dictations: 0, words: 0, spokenDuration: 0, notDelivered: 0)

    public init(dictations: Int, words: Int, spokenDuration: TimeInterval, notDelivered: Int) {
        self.dictations = dictations
        self.words = words
        self.spokenDuration = spokenDuration
        self.notDelivered = notDelivered
    }

    /// Typing the same words at 40 per minute, minus the time spent speaking.
    public var estimatedTimeSaved: TimeInterval {
        max(0, Double(words) / DictationStatsCalendar.typingWordsPerMinute * 60 - spokenDuration)
    }
}

public struct DictationStatsDay: Equatable, Sendable {
    public let day: String
    public let totals: DictationStatsTotals

    public init(day: String, totals: DictationStatsTotals) {
        self.day = day
        self.totals = totals
    }
}

public struct DictationStatsApplication: Equatable, Sendable {
    public let name: String
    public let dictations: Int
    public let words: Int

    public init(name: String, dictations: Int, words: Int) {
        self.name = name
        self.dictations = dictations
        self.words = words
    }
}

/// A range of days, oldest first with empty days filled, and the busiest apps.
public struct DictationStatsSummary: Equatable, Sendable {
    public let days: [DictationStatsDay]
    public let topApplications: [DictationStatsApplication]

    public init(days: [DictationStatsDay], topApplications: [DictationStatsApplication]) {
        self.days = days
        self.topApplications = topApplications
    }

    public var totals: DictationStatsTotals {
        days.reduce(into: .zero) { sum, day in
            sum.dictations += day.totals.dictations
            sum.words += day.totals.words
            sum.spokenDuration += day.totals.spokenDuration
            sum.notDelivered += day.totals.notDelivered
        }
    }
}

public enum DictationStatsCalendar {
    public static let retentionDays = 365
    public static let typingWordsPerMinute = 40.0
    public static let topApplicationCount = 5

    public static func day(of date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The `count` days ending with `date`'s day, oldest first.
    public static func days(endingAt date: Date, count: Int, calendar: Calendar) -> [String] {
        (0..<max(count, 0)).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: date).map { day(of: $0, calendar: calendar) }
        }
    }

    public static func isDay(_ value: String) -> Bool {
        value.count == 10 && value.enumerated().allSatisfy { index, character in
            [4, 7].contains(index) ? character == "-" : character.isASCII && character.isNumber
        }
    }

    /// Words as a person would count them: runs of letters or digits.
    public static func wordCount(_ text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }
}
