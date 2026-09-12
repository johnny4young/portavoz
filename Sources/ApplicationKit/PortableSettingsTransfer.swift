import Foundation
import TranscriptionKit

public struct PortableSettingsReview: Equatable, Sendable {
    public let before: [PortableSettingsKey: PortableSettingsValue]
    public let changes: [PortableSettingsKey: PortableSettingsValue]
}

/// Prepare a review from bounded bytes, then revalidate at the actual write seam.
/// This neither reads defaults nor grants permission to start a capability.
public enum PortableSettingsTransfer {
    private struct File: Codable {
        let format: String
        let version: Int
        let settings: [String: PortableSettingsValue]
    }

    public static func export(_ values: [PortableSettingsKey: PortableSettingsValue]) throws -> Data {
        try PortableSettingsValidation.validate(values)
        let file = File(
            format: "portavoz-settings", version: 1,
            settings: Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        guard data.count <= PortableSettingsValidation.maximumFileBytes else { throw PortableSettingsFailure.tooLarge }
        return data
    }

    public static func review(
        _ data: Data, current: [PortableSettingsKey: PortableSettingsValue]
    ) throws -> PortableSettingsReview {
        guard data.count <= PortableSettingsValidation.maximumFileBytes else { throw PortableSettingsFailure.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["format", "version", "settings"],
              let file = try? JSONDecoder().decode(File.self, from: data), file.format == "portavoz-settings"
        else { throw PortableSettingsFailure.invalidFile }
        guard file.version == 1 else { throw PortableSettingsFailure.unsupportedVersion }
        var incoming: [PortableSettingsKey: PortableSettingsValue] = [:]
        for (key, value) in file.settings {
            guard let key = PortableSettingsKey(rawValue: key) else { throw PortableSettingsFailure.unsupportedSetting }
            incoming[key] = value
        }
        try PortableSettingsValidation.validate(current)
        try PortableSettingsValidation.validate(incoming)
        try mergeTextCollections(&incoming, current: current)
        try PortableSettingsValidation.validate(incoming)
        return PortableSettingsReview(before: current, changes: incoming.filter { current[$0.key] != $0.value })
    }

    public static func approvedChanges(
        _ review: PortableSettingsReview,
        current: [PortableSettingsKey: PortableSettingsValue],
        captureActive: Bool
    ) throws -> [PortableSettingsKey: PortableSettingsValue] {
        guard !captureActive else { throw PortableSettingsFailure.captureActive }
        guard current == review.before else { throw PortableSettingsFailure.staleReview }
        return review.changes
    }

    private static func mergeTextCollections(
        _ incoming: inout [PortableSettingsKey: PortableSettingsValue],
        current: [PortableSettingsKey: PortableSettingsValue]
    ) throws {
        if case .text(let new)? = incoming[.replacements], case .text(let old)? = current[.replacements] {
            let combined = try PortableSettingsValidation.replacements(old)
                + PortableSettingsValidation.replacements(new)
            incoming[.replacements] = .text(DictationTextRules.encode(combined))
        }
        if case .text(let new)? = incoming[.vocabulary], case .text(let old)? = current[.vocabulary] {
            var seen = Set<String>()
            let terms = VocabularyPrompt.parse(old + "," + new).filter {
                seen.insert($0.lowercased()).inserted
            }
            incoming[.vocabulary] = .text(terms.joined(separator: ", "))
        }
    }
}
