import ApplicationKit
import Foundation
import PortavozCore

/// Synchronous MainActor validation and mutation keep review admission adjacent
/// to the write. UserDefaults persistence is not a crash-atomic database commit.
@MainActor
struct AppPortableSettingsStore {
    let defaults: UserDefaults
    let temporary: Bool

    func snapshot() throws -> [PortableSettingsKey: PortableSettingsValue] {
        var values: [PortableSettingsKey: PortableSettingsValue] = [:]
        for key in PortableSettingsKey.allCases {
            switch key {
            case .interfaceLanguage:
                let raw = defaults.string(forKey: key.defaultsKey) ?? "system"
                values[key] = .text(AppLanguage.fromStorage(raw).rawValue)
            case .recognitionLanguage:
                values[key] = .text(MeetingLanguagePreferences.transcript(defaults: defaults).persistedValue)
            case .summaryLanguage:
                values[key] = .text(MeetingLanguagePreferences.summary(defaults: defaults).persistedValue)
            case .menuBarVisible, .removeFillers:
                values[key] = .flag((defaults.object(forKey: key.defaultsKey) as? Bool) ?? true)
            case .titleTemplate:
                values[key] = .text(defaults.string(forKey: key.defaultsKey) ?? TitleTemplate.defaultTemplate)
            case .vocabulary:
                values[key] = .text(defaults.string(forKey: key.defaultsKey) ?? "")
            case .dictationLanguage:
                let value = defaults.string(forKey: key.defaultsKey) ?? "auto"
                values[key] = .text(["en", "es"].contains(value) ? value : "auto")
            case .replacements:
                let value = defaults.string(forKey: key.defaultsKey) ?? ""
                values[key] = .text(value.isEmpty ? "[]" : value)
            }
        }
        try PortableSettingsValidation.validate(values)
        return values
    }

    @discardableResult
    func apply(_ review: PortableSettingsReview, captureActive: Bool) throws -> Int {
        let changes = try PortableSettingsTransfer.approvedChanges(
            review, current: snapshot(), captureActive: captureActive)
        var overrides = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        for (key, value) in changes {
            let stored: Any = switch value {
            case .text(let text): text
            case .flag(let flag): flag
            }
            if temporary {
                overrides[key.defaultsKey] = stored
            } else {
                defaults.set(stored, forKey: key.defaultsKey)
                overrides.removeValue(forKey: key.defaultsKey)
            }
        }
        if !changes.isEmpty {
            defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        return changes.count
    }
}

extension PortableSettingsKey {
    @MainActor
    var defaultsKey: String {
        switch self {
        case .interfaceLanguage: AppLanguage.storageKey
        case .recognitionLanguage: MeetingLanguagePreferences.transcriptKey
        case .summaryLanguage: MeetingLanguagePreferences.summaryKey
        case .menuBarVisible: "menuBarEnabled"
        case .titleTemplate: "titleTemplate"
        case .vocabulary: "customVocabulary"
        case .dictationLanguage: DictationController.languageKey
        case .removeFillers: DictationController.fillerFilterKey
        case .replacements: DictationController.replacementsKey
        }
    }
}
