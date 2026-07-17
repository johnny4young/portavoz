import CloudKit
import Foundation
import PortavozCore
import StorageKit

extension CloudMeetingSyncStateStore {
    static func payloadFileName(for envelope: MeetingSyncEnvelope) -> String {
        let meeting = envelope.meetingID.rawValue.uuidString.lowercased()
        let source = envelope.sourceDeviceID.uuidString.lowercased()
        return "\(meeting).\(source).g\(envelope.generation).json"
    }

    static func deferredPayloadFileName(for envelope: MeetingSyncEnvelope) -> String {
        "remote.\(payloadFileName(for: envelope))"
    }

    static func meetingID(for recordID: CKRecord.ID) -> MeetingID? {
        let prefix = "meeting."
        guard recordID.zoneID == CloudMeetingRecordCodec.zoneID,
              recordID.recordName.hasPrefix(prefix),
              let uuid = UUID(uuidString: String(recordID.recordName.dropFirst(prefix.count)))
        else { return nil }
        return MeetingID(rawValue: uuid)
    }

    static func prepareDirectory(_ sourceURL: URL) throws {
        var url = sourceURL
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func writeProtected(_ data: Data, to sourceURL: URL) throws {
        var url = sourceURL
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func loadSnapshot(from url: URL) throws -> CloudMeetingSyncSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CloudMeetingSyncSnapshot()
        }
        return try decoder().decode(
            CloudMeetingSyncSnapshot.self,
            from: Data(contentsOf: url))
    }

    static func validate(
        _ snapshot: CloudMeetingSyncSnapshot,
        payloadDirectory: URL
    ) throws {
        try validateSnapshotShape(snapshot)
        try validateAttempts(snapshot.attempts, payloadDirectory: payloadDirectory)
        try validateDeferredReplays(
            snapshot.deferredReplays,
            payloadDirectory: payloadDirectory)
        try validateRecordMetadata(snapshot.recordMetadata)
        if let data = snapshot.engineStateData {
            _ = try decoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
    }

    static func validateSnapshotShape(_ snapshot: CloudMeetingSyncSnapshot) throws {
        guard snapshot.formatVersion == CloudMeetingSyncSnapshot.currentFormatVersion else {
            throw CloudMeetingTransportError.invalidState(
                "unsupported transport state format")
        }
        let meetingIDs = snapshot.attempts.map(\.meetingID)
        guard Set(meetingIDs).count == meetingIDs.count else {
            throw CloudMeetingTransportError.invalidState("duplicate outgoing attempt")
        }
        let cursorKeys = snapshot.replayCursors.map {
            "\($0.meetingID.rawValue.uuidString).\($0.sourceDeviceID.uuidString)"
        }
        guard Set(cursorKeys).count == cursorKeys.count else {
            throw CloudMeetingTransportError.invalidState("duplicate replay cursor")
        }
        guard snapshot.replayCursors.allSatisfy({
            $0.generation > 0 && $0.payloadSHA256.count == 64
        }) else {
            throw CloudMeetingTransportError.invalidState("invalid replay cursor")
        }
        let metadataIDs = snapshot.recordMetadata.map(\.meetingID)
        guard Set(metadataIDs).count == metadataIDs.count else {
            throw CloudMeetingTransportError.invalidState("duplicate record metadata")
        }
        let deferredIDs = snapshot.deferredReplays.map(\.meetingID)
        guard Set(deferredIDs).count == deferredIDs.count else {
            throw CloudMeetingTransportError.invalidState("duplicate deferred replay")
        }
        try validateAccountState(snapshot)
    }

    static func validateAccountState(_ snapshot: CloudMeetingSyncSnapshot) throws {
        for fingerprint in [
            snapshot.currentAccountFingerprint,
            snapshot.accountScopeFingerprint,
            snapshot.consentedAccountFingerprint,
            snapshot.initialSeedAccountFingerprint
        ].compactMap({ $0 }) where fingerprint.count != 64 {
            throw CloudMeetingTransportError.invalidState("invalid account fingerprint")
        }
        let accountIsAvailable = snapshot.accountStatus == .available
        guard accountIsAvailable == (snapshot.currentAccountFingerprint != nil) else {
            throw CloudMeetingTransportError.invalidState("inconsistent account availability")
        }
        if let current = snapshot.currentAccountFingerprint,
           snapshot.accountScopeFingerprint != current {
            throw CloudMeetingTransportError.invalidState("current account is outside its scope")
        }
        guard (snapshot.consentedAccountFingerprint == nil)
            == (snapshot.consentGrantedAt == nil)
        else {
            throw CloudMeetingTransportError.invalidState("incomplete consent state")
        }
        if let consented = snapshot.consentedAccountFingerprint,
           snapshot.accountScopeFingerprint != consented {
            throw CloudMeetingTransportError.invalidState("consent belongs to another account")
        }
        let seedHasAccount = snapshot.initialSeedAccountFingerprint != nil
        let seedHasRequest = snapshot.initialSeedRequestedAt != nil
        guard seedHasAccount == seedHasRequest,
              snapshot.initialSeedCompletedAt == nil || seedHasRequest
        else {
            throw CloudMeetingTransportError.invalidState("incomplete initial seed state")
        }
        if let seedAccount = snapshot.initialSeedAccountFingerprint,
           snapshot.accountScopeFingerprint != seedAccount {
            throw CloudMeetingTransportError.invalidState("initial seed belongs to another account")
        }
        let hasAccountScopedState = snapshot.engineStateData != nil
            || !snapshot.recordMetadata.isEmpty
            || !snapshot.replayCursors.isEmpty
            || !snapshot.deferredReplays.isEmpty
            || snapshot.consentedAccountFingerprint != nil
            || snapshot.initialSeedAccountFingerprint != nil
        guard !hasAccountScopedState || snapshot.accountScopeFingerprint != nil else {
            throw CloudMeetingTransportError.invalidState("account-scoped state has no account")
        }
    }

    static func validateAttempts(
        _ attempts: [CloudSyncAttempt],
        payloadDirectory: URL
    ) throws {
        for attempt in attempts {
            guard attempt.generation > 0,
                  attempt.attemptCount >= 0,
                  attempt.payloadByteCount > 0,
                  attempt.payloadSHA256.count == 64,
                  attempt.payloadFileName == payloadFileName(
                    meetingID: attempt.meetingID,
                    sourceDeviceID: attempt.sourceDeviceID,
                    generation: attempt.generation)
            else {
                throw CloudMeetingTransportError.invalidState("invalid outgoing attempt")
            }
            switch attempt.phase {
            case .ready:
                guard attempt.attemptCount >= 0,
                      attempt.lastFailure == nil,
                      attempt.nextRetryAt != nil
                else {
                    throw CloudMeetingTransportError.invalidState("invalid ready attempt")
                }
            case .retryWaiting:
                guard attempt.attemptCount > 0,
                      attempt.lastFailure != nil,
                      attempt.lastFailure != .terminal,
                      attempt.nextRetryAt != nil
                else {
                    throw CloudMeetingTransportError.invalidState("invalid retry attempt")
                }
            case .blocked:
                guard attempt.attemptCount > 0,
                      attempt.lastFailure == .terminal,
                      attempt.nextRetryAt == nil
                else {
                    throw CloudMeetingTransportError.invalidState("invalid blocked attempt")
                }
            }
            let url = payloadDirectory.appendingPathComponent(attempt.payloadFileName)
            let payload = try protectedPayload(
                at: url,
                byteCount: attempt.payloadByteCount,
                sha256: attempt.payloadSHA256)
            let envelope = try MeetingSyncEnvelopeCodec.decode(payload)
            guard envelope.meetingID == attempt.meetingID,
                  envelope.sourceDeviceID == attempt.sourceDeviceID,
                  envelope.generation == attempt.generation
            else {
                throw CloudMeetingTransportError.payloadCorrupted
            }
        }
    }

    static func validateRecordMetadata(
        _ metadataValues: [CloudSyncRecordMetadata]
    ) throws {
        for metadata in metadataValues {
            let record = try CloudRecordSystemFieldsCodec.decode(metadata.systemFields)
            guard record.recordType == CloudMeetingRecordCodec.recordType,
                  record.recordID == CloudMeetingRecordCodec.recordID(for: metadata.meetingID)
            else {
                throw CloudMeetingTransportError.invalidState(
                    "record metadata has the wrong identity")
            }
        }
    }

    static func validateDeferredReplays(
        _ replays: [CloudSyncDeferredReplay],
        payloadDirectory: URL
    ) throws {
        for replay in replays {
            guard replay.generation > 0,
                  replay.payloadByteCount > 0,
                  replay.payloadSHA256.count == 64,
                  replay.payloadFileName == deferredPayloadFileName(
                    meetingID: replay.meetingID,
                    sourceDeviceID: replay.sourceDeviceID,
                    generation: replay.generation)
            else {
                throw CloudMeetingTransportError.invalidState("invalid deferred replay")
            }
            let url = payloadDirectory.appendingPathComponent(replay.payloadFileName)
            let payload = try protectedPayload(
                at: url,
                byteCount: replay.payloadByteCount,
                sha256: replay.payloadSHA256)
            let envelope = try MeetingSyncEnvelopeCodec.decode(payload)
            guard envelope.meetingID == replay.meetingID,
                  envelope.sourceDeviceID == replay.sourceDeviceID,
                  envelope.generation == replay.generation
            else {
                throw CloudMeetingTransportError.payloadCorrupted
            }
        }
    }

    static func protectedPayload(
        at url: URL,
        byteCount: Int,
        sha256: String
    ) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CloudMeetingTransportError.payloadMissing
        }
        let payload = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard payload.count == byteCount,
              MeetingSyncEnvelopeCodec.sha256(payload) == sha256
        else {
            throw CloudMeetingTransportError.payloadCorrupted
        }
        return payload
    }

    static func payloadFileName(
        meetingID: MeetingID,
        sourceDeviceID: UUID,
        generation: Int
    ) -> String {
        "\(meetingID.rawValue.uuidString.lowercased())."
            + "\(sourceDeviceID.uuidString.lowercased()).g\(generation).json"
    }

    static func deferredPayloadFileName(
        meetingID: MeetingID,
        sourceDeviceID: UUID,
        generation: Int
    ) -> String {
        "remote."
            + payloadFileName(
                meetingID: meetingID,
                sourceDeviceID: sourceDeviceID,
                generation: generation)
    }

    static func removeOrphanedPayloads(
        in directory: URL,
        referencedBy fileNames: [String]
    ) throws {
        let referenced = Set(fileNames)
        for url in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
        where !referenced.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
