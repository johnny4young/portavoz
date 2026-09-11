import GRDB
import XCTest
@testable import StorageKit

extension MeetingRecord {
    /// Frozen v6–v49 row shape. Historical migration seeds must not encode
    /// newly added current-model columns into a database that predates them.
    func insertPreCaptureReportFixture(_ db: Database) throws {
        XCTAssertNil(captureReport, "legacy rows cannot carry future capture evidence")
        try db.execute(sql: """
            INSERT INTO meeting
            (id,title,startedAt,endedAt,language,audioDirectory,retention,visibility,
             lifecycleState,transcriptRevision,lastProcessingError,createdAt,updatedAt,deletedAt)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, arguments: [
                id, title, startedAt, endedAt, language, audioDirectory, retention, visibility,
                lifecycleState, transcriptRevision, lastProcessingError, createdAt, updatedAt, deletedAt
            ])
    }
}
