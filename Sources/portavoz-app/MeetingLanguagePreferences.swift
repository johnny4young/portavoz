import Foundation
import PortavozCore

/// UserDefaults is an app adapter; policy semantics stay in PortavozCore.
/// A summary's explicit per-meeting override is persisted by its immutable
/// snapshot, while schema v6 will add durable meetingPreference rows.
@MainActor
enum MeetingLanguagePreferences {
    static let transcriptKey = "transcriptionLanguage"
    static let summaryKey = "summaryLanguage"

    static func transcript(
        defaults: UserDefaults = .standard
    ) -> TranscriptLanguagePolicy {
        TranscriptLanguagePolicy(persistedValue: defaults.string(forKey: transcriptKey))
    }

    static func summary(
        defaults: UserDefaults = .standard
    ) -> SummaryLanguagePolicy {
        SummaryLanguagePolicy(persistedValue: defaults.string(forKey: summaryKey))
    }

    static func resolvedSummaryLanguage(
        spokenLanguage: String?, locale: Locale = AppLanguage.current.locale,
        defaults: UserDefaults = .standard
    ) -> LanguageCode {
        summary(defaults: defaults).resolve(
            spokenLanguage: spokenLanguage,
            fallbackLanguage: locale.language.languageCode?.identifier)
    }
}
