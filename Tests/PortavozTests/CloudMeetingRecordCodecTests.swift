import CloudKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit
import XCTest

final class CloudMeetingRecordCodecTests: XCTestCase {
    func testInlinePayloadUsesEncryptedValuesAndRoundTrips() throws {
        let envelope = makeEnvelope()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let encoded = try CloudMeetingRecordCodec().encode(
            envelope,
            assetDirectory: directory)

        XCTAssertNil(encoded.assetURL)
        XCTAssertEqual(encoded.record.recordType, CloudMeetingRecordCodec.recordType)
        XCTAssertEqual(
            encoded.record.recordID,
            CloudMeetingRecordCodec.recordID(for: envelope.meetingID))
        XCTAssertTrue(encoded.record.encryptedValues.allKeys().contains("payload"))
        XCTAssertTrue(encoded.record.encryptedValues.allKeys().contains("payloadSHA256"))
        let decoded = try CloudMeetingRecordCodec().decode(encoded.record)
        assertEquivalent(decoded, envelope)
    }

    func testOversizedPayloadUsesProtectedAssetAndRoundTrips() throws {
        let envelope = makeEnvelope()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = CloudMeetingRecordCodec(inlinePayloadLimit: 1)

        let encoded = try codec.encode(envelope, assetDirectory: directory)

        let assetURL = try XCTUnwrap(encoded.assetURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
        XCTAssertTrue(try assetURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: assetURL.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: assetURL.path)[.protectionKey]
                as? FileProtectionType,
            .complete)
        XCTAssertTrue(encoded.record.allKeys().contains("payloadAsset"))
        XCTAssertFalse(encoded.record.encryptedValues.allKeys().contains("payload"))
        let decoded = try codec.decode(encoded.record)
        assertEquivalent(decoded, envelope)
    }

    func testChecksumRejectsTamperedInlinePayload() throws {
        let envelope = makeEnvelope()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = CloudMeetingRecordCodec()
        let encoded = try codec.encode(envelope, assetDirectory: directory)
        let payload: Data = try XCTUnwrap(encoded.record.encryptedValues["payload"])
        encoded.record.encryptedValues["payload"] = payload + Data([0])

        XCTAssertThrowsError(try codec.decode(encoded.record)) { error in
            XCTAssertEqual(error as? CloudMeetingRecordCodecError, .checksumMismatch)
        }
    }

    func testMixedInlineAndAssetStorageFailsClosed() throws {
        let envelope = makeEnvelope()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = CloudMeetingRecordCodec()
        let encoded = try codec.encode(envelope, assetDirectory: directory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let foreignAsset = directory.appendingPathComponent("foreign")
        try Data("not the payload".utf8).write(to: foreignAsset, options: .atomic)
        encoded.record["payloadAsset"] = CKAsset(fileURL: foreignAsset)

        XCTAssertThrowsError(try codec.decode(encoded.record)) { error in
            XCTAssertEqual(error as? CloudMeetingRecordCodecError, .missingPayload)
        }
    }

    func testRecordMetadataAndExistingRecordIdentityFailClosed() throws {
        let envelope = makeEnvelope()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = CloudMeetingRecordCodec()
        let wrongType = CKRecord(
            recordType: "Other",
            recordID: CloudMeetingRecordCodec.recordID(for: envelope.meetingID))
        XCTAssertThrowsError(try codec.encode(
            envelope,
            existingRecord: wrongType,
            assetDirectory: directory)) { error in
            XCTAssertEqual(error as? CloudMeetingRecordCodecError, .invalidRecordType)
        }

        let encoded = try codec.encode(envelope, assetDirectory: directory)
        encoded.record["formatVersion"] = 2
        XCTAssertThrowsError(try codec.decode(encoded.record)) { error in
            XCTAssertEqual(error as? CloudMeetingRecordCodecError, .unsupportedFormat)
        }
    }

    func testDeletionIsAnEncryptedTombstoneSaveNotARecordDelete() throws {
        let original = makeEnvelope()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = CloudMeetingRecordCodec()
        let first = try codec.encode(original, assetDirectory: directory)
        let deletion = MeetingSyncEnvelope(
            meetingID: original.meetingID,
            sourceDeviceID: original.sourceDeviceID,
            generation: original.generation + 1,
            changedAt: original.changedAt.addingTimeInterval(1),
            mutation: .delete)

        let encoded = try codec.encode(
            deletion,
            existingRecord: first.record,
            assetDirectory: directory)

        XCTAssertTrue(encoded.record === first.record)
        XCTAssertTrue(encoded.record.encryptedValues.allKeys().contains("payload"))
        let decoded = try codec.decode(encoded.record)
        guard case .delete = decoded.mutation else {
            return XCTFail("Deletion must remain a saved tombstone envelope")
        }
    }

    private func makeEnvelope() -> MeetingSyncEnvelope {
        let meetingID = MeetingID(rawValue: UUID(
            uuidString: "20000000-0000-0000-0000-000000000001")!)
        let meeting = Meeting(
            id: meetingID,
            title: "Private roadmap",
            startedAt: Date(timeIntervalSince1970: 1_784_300_000),
            language: "es")
        let aggregate = MeetingSyncAggregate(
            meeting: MeetingSyncTimed(
                value: meeting,
                createdAt: meeting.startedAt,
                updatedAt: meeting.startedAt),
            speakers: [],
            segments: [],
            summaries: [],
            contextItems: [],
            companionCards: [])
        return MeetingSyncEnvelope(
            meetingID: meetingID,
            sourceDeviceID: UUID(
                uuidString: "20000000-0000-0000-0000-000000000002")!,
            generation: 7,
            changedAt: meeting.startedAt,
            mutation: .upsert(aggregate))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-cloud-codec-tests")
            .appendingPathComponent(UUID().uuidString)
    }

    private func assertEquivalent(
        _ actual: MeetingSyncEnvelope,
        _ expected: MeetingSyncEnvelope,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.meetingID, expected.meetingID, file: file, line: line)
        XCTAssertEqual(actual.sourceDeviceID, expected.sourceDeviceID, file: file, line: line)
        XCTAssertEqual(actual.generation, expected.generation, file: file, line: line)
        guard case .upsert(let aggregate) = actual.mutation else {
            return XCTFail("Expected aggregate", file: file, line: line)
        }
        XCTAssertEqual(aggregate.meeting.value.title, "Private roadmap", file: file, line: line)
    }
}
