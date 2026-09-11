import Foundation

/// Shared fail-closed validation for model prose that cites a bounded numbered
/// evidence list. Every bracket must be an exact in-range marker and every
/// sentence must carry at least one marker before generated prose is admitted.
enum NumberedCitationAnswer {
    private static let expression = try? NSRegularExpression(
        pattern: #"\[(\d+)\]"#)

    static func exactIndexes(
        in raw: String,
        evidenceCount: Int
    ) -> [Int]? {
        guard evidenceCount > 0, let expression else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = expression.matches(in: raw, range: range)
        var seen: Set<Int> = []
        var indexes: [Int] = []
        for match in matches {
            guard let numberRange = Range(match.range(at: 1), in: raw),
                  let number = Int(raw[numberRange]),
                  (1...evidenceCount).contains(number)
            else { return nil }
            if seen.insert(number - 1).inserted {
                indexes.append(number - 1)
            }
        }
        guard !indexes.isEmpty else { return nil }

        var withoutMarkers = raw
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: withoutMarkers) else {
                return nil
            }
            withoutMarkers.removeSubrange(fullRange)
        }
        guard !withoutMarkers.contains("["),
              !withoutMarkers.contains("]"),
              everySentenceHasCitation(raw, expression: expression)
        else { return nil }
        return indexes
    }

    private static func everySentenceHasCitation(
        _ raw: String,
        expression: NSRegularExpression
    ) -> Bool {
        var sentences: [String] = []
        raw.enumerateSubstrings(
            in: raw.startIndex..<raw.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            sentences.append(String(raw[range]))
        }
        guard !sentences.isEmpty else { return false }
        return sentences.allSatisfy { sentence in
            let range = NSRange(
                sentence.startIndex..<sentence.endIndex,
                in: sentence)
            return expression.firstMatch(in: sentence, range: range) != nil
        }
    }
}
