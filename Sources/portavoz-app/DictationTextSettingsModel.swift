import Foundation
import Observation
import PortavozCore

/// Settings commands own preference writes; SwiftUI only renders the observable snapshot.
@MainActor
@Observable
final class DictationTextSettingsModel {
    enum SelectionError { case invalidApplication, unavailableWindow }
    private(set) var globalMode: DictationTextMode
    private(set) var profiles: [DictationApplicationTextProfile] = []
    private(set) var hasInvalidProfiles = false
    private(set) var selectionError: SelectionError?
    private(set) var isSelectingApplication = false
    /// Whether any session can use Clean mode, the only mode that applies the
    /// filler filter and replacement rules. Unreadable profiles fall back to
    /// the default mode at runtime, so they do not count.
    var cleanModeInUse: Bool {
        globalMode == .clean || (!hasInvalidProfiles && profiles.contains { $0.mode == .clean })
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let temporary: Bool

    init(defaults: UserDefaults, temporary: Bool) {
        self.defaults = defaults
        self.temporary = temporary
        DictationTextPreferences.initialize(in: defaults, temporary: temporary)
        globalMode = DictationTextPreferences.globalMode(in: defaults)
        do {
            profiles = try DictationTextPreferences.decodeProfiles(
                defaults.string(forKey: DictationTextPreferences.profilesKey) ?? "[]")
        } catch { hasInvalidProfiles = true }
    }

    func setGlobalMode(_ mode: DictationTextMode) {
        write(mode.rawValue, forKey: DictationTextPreferences.modeKey)
        globalMode = mode
    }

    func setProfile(bundleIdentifier: String, mode: DictationTextMode) {
        guard !hasInvalidProfiles, DictationTextPreferences.isValidBundleIdentifier(bundleIdentifier) else {
            selectionError = .invalidApplication
            return
        }
        var updated = profiles.filter { $0.bundleIdentifier != bundleIdentifier }
        updated.append(.init(bundleIdentifier: bundleIdentifier, mode: mode))
        save(updated)
    }

    func removeProfile(bundleIdentifier: String) {
        guard !hasInvalidProfiles else { return }
        save(profiles.filter { $0.bundleIdentifier != bundleIdentifier })
    }

    func beginApplicationSelection() -> Bool {
        guard !isSelectingApplication, !hasInvalidProfiles else { return false }
        isSelectingApplication = true
        selectionError = nil
        return true
    }

    func finishApplicationSelection() { isSelectingApplication = false }
    func resetProfiles() { save([]) }
    func reportSelectionError(_ error: SelectionError = .invalidApplication) { selectionError = error }

    private func save(_ updated: [DictationApplicationTextProfile]) {
        do {
            let json = try DictationTextPreferences.encodeProfiles(updated)
            write(json, forKey: DictationTextPreferences.profilesKey)
            profiles = updated.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
            hasInvalidProfiles = false
            selectionError = nil
        } catch { selectionError = .invalidApplication }
    }

    private func write(_ value: String, forKey key: String) {
        if temporary {
            var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            domain[key] = value
            defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        } else {
            defaults.set(value, forKey: key)
        }
    }
}
