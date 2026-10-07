import Foundation
import PortavozCore
import TranscriptionKit

/// One bounded preference snapshot for one captured destination. It owns no platform input.
struct DictationTextPreferenceSnapshot: Sendable {
    var mode: DictationTextMode
    let removeFillers: Bool
    let replacements: [DictationReplacement]

    /// No session: nothing optional applies.
    static let inert = Self(mode: .literal, removeFillers: false, replacements: [])

    func applying(to text: String) -> String {
        DictationTextRules.apply(
            text, replacements: mode == .clean ? replacements : [],
            removeFillers: mode == .clean && removeFillers)
    }
}

@MainActor
enum DictationTextPreferences {
    static let modeKey = "dictationTextMode"
    static let profilesKey = "dictationApplicationTextProfiles"
    static let maximumProfiles = 64
    static let maximumProfileBytes = 32_768

    enum ProfileFailure: Error { case invalid, tooMany }

    /// Call before the first enable toggle can create the legacy marker. The temporary
    /// app initializes only its volatile domain, never a persistent preference file.
    static func initialize(in defaults: UserDefaults, temporary: Bool) {
        guard defaults.object(forKey: modeKey) == nil else { return }
        store(globalMode(in: defaults).rawValue, forKey: modeKey, in: defaults, temporary: temporary)
    }

    /// The temporary app writes only its volatile argument domain, never a preference file.
    static func store(_ value: String, forKey key: String, in defaults: UserDefaults, temporary: Bool) {
        if temporary {
            var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            domain[key] = value
            defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        } else {
            defaults.set(value, forKey: key)
        }
    }

    static func globalMode(in defaults: UserDefaults) -> DictationTextMode {
        if let raw = defaults.string(forKey: modeKey), let mode = DictationTextMode(rawValue: raw) { return mode }
        // Presence matters: a saved false filler/enable choice must not be mistaken for absence.
        let legacyKeys = [DictationController.defaultsKey, DictationController.languageKey,
                          DictationController.fillerFilterKey, DictationController.replacementsKey]
        return legacyKeys.contains { defaults.object(forKey: $0) != nil } ? .clean : .literal
    }

    static func snapshot(
        in defaults: UserDefaults, bundleIdentifier: String?
    ) -> DictationTextPreferenceSnapshot {
        let profiles = (try? decodeProfiles(defaults.string(forKey: profilesKey) ?? "[]")) ?? []
        let profile = profiles.first { $0.bundleIdentifier == bundleIdentifier }
        return DictationTextPreferenceSnapshot(
            mode: profile?.mode ?? globalMode(in: defaults),
            removeFillers: DictationController.fillerFilterEnabled(in: defaults),
            replacements: DictationTextRules.decode(
                replacements: defaults.string(forKey: DictationController.replacementsKey) ?? ""))
    }

    static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255 else { return false }
        return value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    static func decodeProfiles(_ json: String) throws -> [DictationApplicationTextProfile] {
        guard json.utf8.count <= maximumProfileBytes, let data = json.data(using: .utf8),
              let profiles = try? JSONDecoder().decode([DictationApplicationTextProfile].self, from: data)
        else { throw ProfileFailure.invalid }
        try validate(profiles)
        return profiles.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    static func encodeProfiles(_ profiles: [DictationApplicationTextProfile]) throws -> String {
        try validate(profiles)
        let ordered = profiles.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        let data = try JSONEncoder().encode(ordered)
        guard data.count <= maximumProfileBytes, let json = String(data: data, encoding: .utf8)
        else { throw ProfileFailure.invalid }
        return json
    }

    private static func validate(_ profiles: [DictationApplicationTextProfile]) throws {
        guard profiles.count <= maximumProfiles else { throw ProfileFailure.tooMany }
        guard profiles.allSatisfy({ isValidBundleIdentifier($0.bundleIdentifier) }),
              Set(profiles.map(\.bundleIdentifier)).count == profiles.count else { throw ProfileFailure.invalid }
    }
}
