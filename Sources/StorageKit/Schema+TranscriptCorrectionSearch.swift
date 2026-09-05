import Foundation
import GRDB
import PortavozCore

extension StorageSchema {
    /// v36 (D329): sparse effective correction lineage for bounded search
    /// projections. Accepted meetings need no row; an active overlay stores
    /// only its opaque revision and accepted-transcript revision.
    static func registerTranscriptCorrectionSearchMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v36") { database in
            try database.create(table: "transcriptCorrectionSearchState") { table in
                table.primaryKey("meetingID", .text)
                    .references("meeting", onDelete: .cascade)
                table.column("baseTranscriptRevision", .integer).notNull()
                    .check(sql: "baseTranscriptRevision >= 0")
                table.column("correctionRevision", .text).notNull()
                    .check(sql: "length(correctionRevision) = 64")
            }

            // Existing corrected libraries must receive the lineage fence
            // before Spotlight can treat their summary or transcript as
            // current. Only meetings with correction history need work.
            let meetingKeys = try String.fetchAll(
                database,
                sql: "SELECT DISTINCT meetingID FROM transcriptCorrection")
            for key in meetingKeys {
                guard let identifier = UUID(uuidString: key) else { continue }
                try MeetingStore.refreshTranscriptCorrectionSearchProjection(
                    meetingID: MeetingID(rawValue: identifier),
                    in: database)
            }
        }
    }
}
