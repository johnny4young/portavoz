import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Destructive replacement requires one live, canonical recording owner.
    /// An import's immutable copy remains Retry authority until job success.
    public func canCompressMeetingAudio(relativeAudioDirectory: String) async throws -> Bool {
        let parts = relativeAudioDirectory.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "Audio",
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        return try await database.read { db in
            // The path has no uniqueness constraint. Even UUID-shaped paths
            // must reject a second owner instead of trusting their first ID.
            let matches = try Self.audioCompressionDirectoryOwners(relativeAudioDirectory).fetchAll(db)
            guard matches.count == 1, let meeting = matches.first, meeting.deletedAt == nil,
                  (try? meeting.meeting) != nil else { return false }
            let jobs = try ProcessingJobRecord
                .filter(Column("meetingID") == meeting.id)
                .filter(Column("kind") == ProcessingJobKind.audioImport.rawValue)
                .limit(2)
                .fetchAll(db)
            let input = try AudioImportInputRecord.fetchOne(db, key: meeting.id)
            guard let input else {
                // A missing authority row must not turn an import into an
                // ordinary recording, even if the job disappeared with it.
                return jobs.isEmpty && !parts.contains(where: { $0.lowercased() == "imports" })
            }
            guard jobs.count == 1, let job = jobs.first,
                  job.id == input.jobID, job.meetingID == input.meetingID,
                  job.inputFingerprint == input.inputFingerprint,
                  let request = try? input.decoded(),
                  request.copyDirectory == relativeAudioDirectory,
                  request.copiedAudioDirectory == relativeAudioDirectory,
                  request.sourceBookmark == nil, request.copiedAudioDigest != nil,
                  meeting.transcriptRevision > 0,
                  let validated = try? job.job else { return false }
            return validated.state == .succeeded
        }
    }

    static func audioCompressionDirectoryOwners(_ directory: String) -> QueryInterfaceRequest<MeetingRecord> {
        MeetingRecord.filter(Column("audioDirectory") == directory).limit(2)
    }
}
