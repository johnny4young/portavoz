import Foundation
import SwiftUI

/// User-facing app UI language. This only affects Portavoz chrome; transcript
/// and summary policies remain independent in Intelligence settings.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case spanish = "es"

    static let storageKey = "app-language"

    var id: String { rawValue }

    var localeIdentifier: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .spanish: "es"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .spanish: Locale(identifier: "es")
        }
    }

    static var current: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: raw) ?? .system
    }

    static func fromStorage(_ rawValue: String) -> AppLanguage {
        AppLanguage(rawValue: rawValue) ?? .system
    }
}

private struct AppLocaleModifier: ViewModifier {
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.system.rawValue

    func body(content: Content) -> some View {
        let language = AppLanguage.fromStorage(appLanguageRaw)
        content.environment(\.locale, language.locale)
    }
}

extension View {
    /// Applies Portavoz's app-only language override to SwiftUI-localized UI.
    func portavozLocalized() -> some View {
        modifier(AppLocaleModifier())
    }
}
