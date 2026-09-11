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
        return ContentDigest.sha256(Data(canonical.utf8))
    }
}

/// Stable content digest shared by application workflows without importing
/// platform cryptography frameworks into their orchestration layer.
public enum ContentDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
