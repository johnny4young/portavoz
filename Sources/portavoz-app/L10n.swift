import Foundation

enum L10n {
    static func text(_ key: String, table: String = "Localizable") -> String {
        localizedString(forKey: key, table: table)
    }

    static func format(_ key: String, table: String = "Localizable", _ arguments: CVarArg...) -> String {
        let format = localizedString(forKey: key, table: table)
        return String(format: format, locale: AppLanguage.current.locale, arguments: arguments)
    }

    private static func localizedString(forKey key: String, table: String) -> String {
        bundle(for: AppLanguage.current).localizedString(forKey: key, value: key, table: table)
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        guard let identifier = language.localeIdentifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return .main
        }
        return bundle
    }
}
