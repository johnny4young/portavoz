import Foundation

/// Advisory hardware guidance is separate from governor admission. These
/// choices never select, download or replace a model, or revoke an active lease.
@MainActor
struct AppModelMemoryPreferences {
    enum Profile: String, CaseIterable, Sendable {
        case balanced
        case lightweight
    }

    static let key = "modelMemoryProfile"
    let defaults: UserDefaults
    let capacity: AppModelMemoryCapacity

    init(defaults: UserDefaults = .standard, physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.defaults = defaults
        self.capacity = AppModelMemoryCapacity(bytes: physicalMemoryBytes)
    }

    var profile: Profile {
        defaults.string(forKey: Self.key).flatMap(Profile.init(rawValue:)) ?? .balanced
    }

    var recommendedProfile: Profile {
        capacity.recommendsLightweight ? .lightweight : .balanced
    }

    func setProfile(_ profile: Profile) {
        defaults.set(profile.rawValue, forKey: Self.key)
    }
}
