/// Stable identity for a device-local secret. Identifiers are domain values;
/// concrete persistence belongs to an outer platform/security adapter.
public struct SecretIdentifier: Hashable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension SecretIdentifier {
    public static let gitHubToken = Self(rawValue: "app.portavoz.github-token")
    public static let linearToken = Self(rawValue: "app.portavoz.linear-token")
    public static let byokAPIKey = Self(rawValue: "app.portavoz.byok-api-key")
    public static let voiceprintKey = Self(rawValue: "app.portavoz.voiceprint-key")
    public static let voiceGalleryKey = Self(rawValue: "app.portavoz.voice-gallery-key")
}

/// Storage port for secrets that must never enter SQLite, UserDefaults, sync,
/// or diagnostics. Implementations must keep values device-local.
public protocol SecretStoring: Sendable {
    func set(_ secret: String, for identifier: SecretIdentifier) throws
    func value(for identifier: SecretIdentifier) throws -> String?
    func delete(_ identifier: SecretIdentifier) throws
}
