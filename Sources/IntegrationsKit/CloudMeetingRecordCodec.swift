import CloudKit
import Foundation
import PortavozCore
import StorageKit

public enum CloudMeetingRecordCodecError: Error, Equatable, Sendable {
    case invalidRecordType
    case invalidRecordIdentity
    case unsupportedFormat
    case invalidStorage
    case missingPayload
    case checksumMismatch
    case payloadIdentityMismatch
}

/// One CKRecord plus the local file that backs a CKAsset until CloudKit has
/// finished saving it. Callers own that file's cleanup after a terminal send.
public struct CloudMeetingEncodedRecord: Sendable {
    public let record: CKRecord
    public let assetURL: URL?

    public init(record: CKRecord, assetURL: URL?) {
        self.record = record
        self.assetURL = assetURL
    }
}

/// Converts Portavoz's transport-neutral envelope into one private-zone
/// CloudKit record. Inline content uses encryptedValues; large content uses a
/// CKAsset, which CloudKit encrypts by default. The local asset file receives
/// complete file protection and never contains audio.
public struct CloudMeetingRecordCodec: Sendable {
    public static let recordType = "MeetingReplica"
    public static let zoneID = CKRecordZone.ID(
        zoneName: "PortavozMeetings",
        ownerName: CKCurrentUserDefaultName)
    public static let defaultInlinePayloadLimit = 512 * 1_024

    private enum Field {
        static let formatVersion = "formatVersion"
        static let storage = "payloadStorage"
        static let inlinePayload = "payload"
        static let assetPayload = "payloadAsset"
        static let payloadSHA256 = "payloadSHA256"
    }

    private enum Storage: String {
        case inline
        case asset
    }

    private static let formatVersion = 1

    public let inlinePayloadLimit: Int

    public init(inlinePayloadLimit: Int = Self.defaultInlinePayloadLimit) {
        precondition(inlinePayloadLimit > 0, "inline payload limit must be positive")
        self.inlinePayloadLimit = inlinePayloadLimit
    }

    public static func recordID(for meetingID: MeetingID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: "meeting.\(meetingID.rawValue.uuidString.lowercased())",
            zoneID: zoneID)
    }

    public func encode(
        _ envelope: MeetingSyncEnvelope,
        existingRecord: CKRecord? = nil,
        assetDirectory: URL
    ) throws -> CloudMeetingEncodedRecord {
        let payload = try MeetingSyncEnvelopeCodec.encode(envelope)
        if payload.count <= inlinePayloadLimit {
            return try encodePayload(
                payload,
                envelope: envelope,
                existingRecord: existingRecord,
                assetURL: nil)
        }

        let assetURL = try writeProtectedAsset(payload, to: assetDirectory)
        do {
            return try encodePayload(
                payload,
                envelope: envelope,
                existingRecord: existingRecord,
                assetURL: assetURL)
        } catch {
            try? FileManager.default.removeItem(at: assetURL)
            throw error
        }
    }

    /// Reuses the exact protected bytes admitted by the durable transport
    /// store. An oversized CKAsset points at that same file, so retries never
    /// regenerate content or leak an untracked temporary copy.
    public func encodeStagedPayload(
        at payloadURL: URL,
        expectedSHA256: String,
        existingRecord: CKRecord? = nil
    ) throws -> CloudMeetingEncodedRecord {
        let payload = try Data(contentsOf: payloadURL, options: [.mappedIfSafe])
        guard MeetingSyncEnvelopeCodec.sha256(payload) == expectedSHA256 else {
            throw CloudMeetingRecordCodecError.checksumMismatch
        }
        let envelope = try MeetingSyncEnvelopeCodec.decode(payload)
        return try encodePayload(
            payload,
            envelope: envelope,
            existingRecord: existingRecord,
            assetURL: payload.count > inlinePayloadLimit ? payloadURL : nil)
    }

    public func decode(_ record: CKRecord) throws -> MeetingSyncEnvelope {
        guard record.recordType == Self.recordType else {
            throw CloudMeetingRecordCodecError.invalidRecordType
        }
        guard record.recordID.zoneID == Self.zoneID,
              let meetingID = Self.meetingID(from: record.recordID)
        else {
            throw CloudMeetingRecordCodecError.invalidRecordIdentity
        }
        let formatVersion: Int? = record[Field.formatVersion]
        guard formatVersion == Self.formatVersion else {
            throw CloudMeetingRecordCodecError.unsupportedFormat
        }
        let storageValue: String? = record[Field.storage]
        guard let storage = storageValue.flatMap(Storage.init(rawValue:)) else {
            throw CloudMeetingRecordCodecError.invalidStorage
        }

        let payload = try payload(from: record, storage: storage)
        let expectedDigest: String? = record.encryptedValues[Field.payloadSHA256]
        guard expectedDigest == MeetingSyncEnvelopeCodec.sha256(payload) else {
            throw CloudMeetingRecordCodecError.checksumMismatch
        }
        let envelope = try MeetingSyncEnvelopeCodec.decode(payload)
        guard envelope.meetingID == meetingID else {
            throw CloudMeetingRecordCodecError.invalidRecordIdentity
        }
        return envelope
    }

    private func encodePayload(
        _ payload: Data,
        envelope: MeetingSyncEnvelope,
        existingRecord: CKRecord?,
        assetURL: URL?
    ) throws -> CloudMeetingEncodedRecord {
        let decoded = try MeetingSyncEnvelopeCodec.decode(payload)
        guard decoded.meetingID == envelope.meetingID,
              decoded.sourceDeviceID == envelope.sourceDeviceID,
              decoded.generation == envelope.generation
        else {
            throw CloudMeetingRecordCodecError.payloadIdentityMismatch
        }
        let recordID = Self.recordID(for: envelope.meetingID)
        let record = try reusableRecord(existingRecord, recordID: recordID)
        record[Field.formatVersion] = Self.formatVersion
        record.encryptedValues[Field.payloadSHA256] = MeetingSyncEnvelopeCodec.sha256(payload)

        if let assetURL {
            record[Field.storage] = Storage.asset.rawValue
            record.encryptedValues[Field.inlinePayload] = nil as Data?
            record[Field.assetPayload] = CKAsset(fileURL: assetURL)
        } else {
            record[Field.storage] = Storage.inline.rawValue
            record.encryptedValues[Field.inlinePayload] = payload
            record[Field.assetPayload] = nil as CKAsset?
        }
        return CloudMeetingEncodedRecord(record: record, assetURL: assetURL)
    }

    private func reusableRecord(
        _ existingRecord: CKRecord?,
        recordID: CKRecord.ID
    ) throws -> CKRecord {
        guard let existingRecord else {
            return CKRecord(recordType: Self.recordType, recordID: recordID)
        }
        guard existingRecord.recordType == Self.recordType else {
            throw CloudMeetingRecordCodecError.invalidRecordType
        }
        guard existingRecord.recordID == recordID else {
            throw CloudMeetingRecordCodecError.invalidRecordIdentity
        }
        return existingRecord
    }

    private func payload(from record: CKRecord, storage: Storage) throws -> Data {
        switch storage {
        case .inline:
            guard record[Field.assetPayload] as CKAsset? == nil,
                  let payload: Data = record.encryptedValues[Field.inlinePayload]
            else {
                throw CloudMeetingRecordCodecError.missingPayload
            }
            return payload
        case .asset:
            guard record.encryptedValues[Field.inlinePayload] as Data? == nil,
                  let asset: CKAsset = record[Field.assetPayload],
                  let fileURL = asset.fileURL
            else {
                throw CloudMeetingRecordCodecError.missingPayload
            }
            return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        }
    }

    private func writeProtectedAsset(_ payload: Data, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path)
        let assetURL = directory
            .appendingPathComponent(UUID().uuidString.lowercased())
            .appendingPathExtension("portavoz-sync")
        try CloudSyncProtectedFile.write(payload, to: assetURL)
        return assetURL
    }

    private static func meetingID(from recordID: CKRecord.ID) -> MeetingID? {
        let prefix = "meeting."
        guard recordID.recordName.hasPrefix(prefix),
              let uuid = UUID(uuidString: String(recordID.recordName.dropFirst(prefix.count)))
        else { return nil }
        return MeetingID(rawValue: uuid)
    }
}
