import Foundation

/// Voices direction B (design system): the stable hue INDEX for a
/// speaker. Named people hash their normalized name — the same person
/// gets the same hue in every meeting, on every launch; unnamed S-labels
/// fall back to their order of appearance. Pure so it's testable; the
/// actual colors live app-side.
public enum VoiceHue {
    public static let paletteSize = 6

    public static func index(name: String?, fallbackOrder: Int) -> Int {
        if let name {
            let normalized = name.lowercased().trimmingCharacters(in: .whitespaces)
            if !normalized.isEmpty {
                // FNV-1a: stable across launches (hashValue is randomized).
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                for byte in normalized.utf8 {
                    hash ^= UInt64(byte)
                    hash = hash &* 0x0100_0000_01b3
                }
                return Int(hash % UInt64(paletteSize))
            }
        }
        return ((fallbackOrder % paletteSize) + paletteSize) % paletteSize
    }
}
