import CryptoKit
import Foundation

/// Stable SHA-256 identity for durable operations. Components are length-
/// prefixed before hashing, so user text cannot make adjacent fields bleed
/// into the same canonical value.
public enum OperationFingerprint {
    public static func make(
        version: String,
        components: [String]
    ) -> String {
        let canonical = ([version] + components).map { component in
            "\(component.utf8.count):\(component)"
        }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
