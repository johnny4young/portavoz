import Foundation

/// The stable hue index a name prefers: the same person gets the same hue in
/// every meeting, on every launch. `VoiceCast` decides who may hold one.
public enum VoiceHue {
    public static let paletteSize = 5

    /// The form two spellings of one name share.
    public static func normalized(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespaces)
    }

    public static func index(name: String) -> Int {
        let normalized = normalized(name)
        // FNV-1a: stable across launches (hashValue is randomized).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0100_0000_01b3
        }
        return Int(hash % UInt64(paletteSize))
    }
}
