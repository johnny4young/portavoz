import CryptoKit
import Foundation

/// The Python evaluators' fixture digest: sorted keys, compact, non-ASCII kept verbatim.
enum CLIPublicFixtureDigest {
    static func sha256(of data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}
