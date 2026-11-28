import Foundation
import PortavozCore

extension ExportLibraryMarkdownBackup {
    enum ResumedPublication {
        case none
        case reuse(LibraryMarkdownBackupRecoveryPublication)
        case landed(LibraryMarkdownBackupRecoveryPublication)
    }

    /// A cancelled publish keeps its journal reservation; retry that exact name
    /// instead of allocating a sibling, and record it if the file already landed.
    static func resumablePublication(
        _ data: Data,
        for content: LibraryMarkdownBackupContent,
        run: ActiveLibraryMarkdownBackupRun,
        files: any LibraryMarkdownBackupFiles,
        in directory: URL
    ) async throws -> ResumedPublication {
        guard let pending = run.recoveryState.pendingPublication,
              pending.meetingID == content.meeting.id,
              pending.sourceCursor == run.pendingSourceCursor,
              pending.sha256 == ContentDigest.sha256(data)
        else { return .none }
        let evidence: BackupPublicationEvidence
        do {
            evidence = try await files.evidence(for: pending, in: directory)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .none
        }
        switch evidence {
        case .matching: return .landed(pending)
        case .missing: return .reuse(pending)
        case .conflicting: return .none
        }
    }

    static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL == rhs.standardizedFileURL
    }

    static func sourceFailure(
        _ failure: LibraryMarkdownBackupSourceFailure
    ) -> LibraryMarkdownBackupFailure {
        LibraryMarkdownBackupFailure(
            meetingID: failure.meetingID,
            title: failure.title,
            stage: .source)
    }

    static func failure(
        for content: LibraryMarkdownBackupContent,
        stage: LibraryMarkdownBackupFailureStage
    ) -> LibraryMarkdownBackupFailure {
        LibraryMarkdownBackupFailure(
            meetingID: content.meeting.id,
            title: content.meeting.title,
            stage: stage)
    }

    static func boundedRecoveryTitle(_ title: String) -> String {
        let maximumBytes = LibraryMarkdownBackupRecoveryFailure.maximumTitleBytes
        guard title.utf8.count > maximumBytes else { return title }
        var bounded = ""
        bounded.reserveCapacity(maximumBytes)
        var byteCount = 0
        for scalar in title.unicodeScalars {
            let scalarByteCount = scalar.utf8.count
            guard byteCount + scalarByteCount <= maximumBytes else { break }
            bounded.unicodeScalars.append(scalar)
            byteCount += scalarByteCount
        }
        return bounded
    }
}
