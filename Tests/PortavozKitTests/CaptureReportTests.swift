import Foundation
import GRDB
import IntegrationsKit
import PortavozCore
import XCTest
@testable import StorageKit

final class CaptureReportTests: XCTestCase {
    private func interrupted() throws -> CaptureReport {
        try CaptureReport(channels: [CaptureChannelReport(
            channel: .microphone, acceptedFrames: 48_010, paddingFrames: 10,
            rejectedFrames: 4, writtenFrames: 48_010, failure: .overloaded)])
    }

    func testEvidenceDistinguishesUnknownCountersAndTimelinePaddingFromCompletePCM() throws {
        XCTAssertFalse(try CaptureReport(channels: [CaptureChannelReport(channel: .system)]).requiresAttention)
        XCTAssertTrue(try interrupted().requiresAttention)
        let padded = try CaptureReport(channels: [CaptureChannelReport(
            channel: .system, acceptedFrames: 10, paddingFrames: 2, rejectedFrames: 0, writtenFrames: 10)])
        XCTAssertTrue(padded.requiresAttention, "conserved silence is still missing original audio")
        let complete = try CaptureReport(channels: [CaptureChannelReport(
            channel: .system, acceptedFrames: 10, paddingFrames: 0, rejectedFrames: 0, writtenFrames: 10)])
        XCTAssertFalse(complete.requiresAttention)
    }

    func testPersistedCaptureReportBytesAreCanonicalAcrossIndependentEncoders() throws {
        let report = try interrupted()
        let expected = try MeetingRecord.encodeCaptureReport(report)
        for _ in 0..<100 { XCTAssertEqual(try MeetingRecord.encodeCaptureReport(report), expected) }
        XCTAssertEqual(try JSONDecoder().decode(CaptureReport.self, from: expected), report)
    }

    func testInvalidOrDuplicateCountsFailClosedAtCodecAdmission() throws {
        for rows in [
            [], [CaptureChannelReport(channel: .system), CaptureChannelReport(channel: .system)],
            [CaptureChannelReport(channel: .system, acceptedFrames: -1)],
            [CaptureChannelReport(channel: .system, acceptedFrames: 2, paddingFrames: 3)],
            [CaptureChannelReport(channel: .system, acceptedFrames: 2, writtenFrames: 3)]
        ] {
            XCTAssertThrowsError(try CaptureReport(channels: rows))
        }
        let corrupt = Data(#"{"channels":[{"channel":"microphone","acceptedFrames":-1,"publicationFailed":false}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureReport.self, from: corrupt))
    }

    func testBundleRoundTripAndIdentityRemapPreserveReportWhileLegacyMeansUnknown() throws {
        var meeting = Meeting(title: "Public synthetic capture", startedAt: Date(), captureReport: try interrupted())
        let bundle = MeetingBundle(meeting: meeting, speakers: [], segments: [])
        let remapped = try MeetingBundle.decode(bundle.encoded()).remappedForImport()
        XCTAssertNotEqual(remapped.meeting.id, meeting.id)
        XCTAssertEqual(remapped.meeting.captureReport, meeting.captureReport)
        meeting.captureReport = nil
        let legacy = try JSONEncoder().encode(meeting)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("captureReport"))
        XCTAssertNil(try JSONDecoder().decode(Meeting.self, from: legacy).captureReport)
    }

    func testReopenAndSuccessfulProcessingStateCannotEraseCaptureFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        var meeting = Meeting(title: "Synthetic", startedAt: Date(), captureReport: try interrupted())
        do {
            let store = try MeetingStore(databaseURL: url)
            try await store.save(meeting)
            meeting.lifecycleState = .ready
            meeting.lastProcessingError = nil
            try await store.save(meeting)
        }
        let reopened = try MeetingStore(databaseURL: url)
        let stored = try await reopened.detail(meeting.id)
        XCTAssertEqual(stored?.meeting.captureReport, meeting.captureReport)
        XCTAssertTrue(stored?.meeting.captureReport?.requiresAttention == true)
    }

    func testSchema49MigrationRetainsLegacyRowsAsUnknown() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v49")
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO meeting(id,title,startedAt,retention,visibility,lifecycleState,transcriptRevision,createdAt,updatedAt)
                VALUES (?, 'Legacy', 0, '{"keep":{}}', 'private', 'ready', 0, 0, 0)
                """, arguments: [UUID().uuidString])
        }
        try migrator.migrate(database)
        try database.read { db in
            let row = try XCTUnwrap(MeetingRecord.fetchOne(db))
            XCTAssertNil(try row.meeting.captureReport)
        }
    }
}
