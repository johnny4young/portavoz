import CryptoKit
import Foundation
import StorageKit

/// Deterministic JSON boundary shared by CloudKit's encrypted inline and asset
/// paths. CKRecord construction remains a later adapter concern; neither this
/// codec nor the StorageKit envelope imports CloudKit or performs network work.
public enum MeetingSyncEnvelopeCodec {
    public static func encode(_ envelope: MeetingSyncEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> MeetingSyncEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(MeetingSyncEnvelope.self, from: data)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
