import AudioCaptureKit
import Foundation

/// Shared interpretation of the existing Audio preference. A temporarily
/// missing device falls back for this capture without erasing the user's UID.
struct MicrophoneInputSelection: Equatable {
    let deviceIdentifier: String?
    let usesSystemFallback: Bool

    static func preferredIdentifier(defaults: UserDefaults) -> String? {
        guard let value = defaults.object(forKey: "preferredInputUID") as? String,
              !value.isEmpty, value != "default" else { return nil }
        return value
    }

    static func resolve(
        _ preferredIdentifier: String?,
        isAvailable: (String) -> Bool = { (try? AudioDeviceCatalog.inputDevice(matching: $0)) != nil }
    ) -> Self {
        guard let preferredIdentifier else {
            return Self(deviceIdentifier: nil, usesSystemFallback: false)
        }
        return isAvailable(preferredIdentifier)
            ? Self(deviceIdentifier: preferredIdentifier, usesSystemFallback: false)
            : Self(deviceIdentifier: nil, usesSystemFallback: true)
    }
}
