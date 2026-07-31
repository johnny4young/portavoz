import Foundation

struct BackupFileNameAllocator {
    private static let portableReservedNames: Set<String> = [
        "aux", "con", "nul", "prn",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"
    ]
    private var used: Set<String>
    private var nextSuffix: [String: Int] = [:]

    init(existing: Set<String>) {
        used = Set(existing.map(Self.collisionKey))
    }

    mutating func nextFileName(for title: String) -> String {
        let base = Self.sanitized(title)
        let key = Self.collisionKey(base)
        var suffix = nextSuffix[key] ?? 1
        while true {
            let stem = suffix == 1 ? base : "\(base) \(suffix)"
            let fileName = "\(stem).md"
            suffix += 1
            guard used.insert(Self.collisionKey(fileName)).inserted else { continue }
            nextSuffix[key] = suffix
            return fileName
        }
    }

    private static func sanitized(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        var cleaned = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = String(cleaned.prefix(120))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cleaned.isEmpty else { return "meeting" }

        let deviceStem = cleaned.split(separator: ".", maxSplits: 1)
            .first.map(String.init) ?? cleaned
        if portableReservedNames.contains(collisionKey(deviceStem)) {
            return "meeting-\(cleaned)"
        }
        return cleaned
    }

    private static func collisionKey(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
    }
}
