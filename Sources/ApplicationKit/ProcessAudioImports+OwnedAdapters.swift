import Foundation
import PortavozCore
import StorageKit

struct OwnedImportAudio: ImportMeetingAudioFiles {
    let copy: AudioImportCopy

    func copySystemAudio(from source: URL, meetingID: MeetingID) throws -> ImportedMeetingAudio {
        try Task.checkCancellation()
        return ImportedMeetingAudio(fileURL: copy.fileURL, relativeDirectory: copy.relativeDirectory)
    }

    func discardImportedAudio(_ audio: ImportedMeetingAudio) {
        // The queue published this copy before model work. A model failure
        // preserves it for explicit retry; ephemeral import rollback no longer owns it.
    }
}

struct OwnedImportPreferences: ImportMeetingPreferences {
    let value: ImportMeetingPreferencesSnapshot
    func importMeetingPreferences() -> ImportMeetingPreferencesSnapshot { value }
}

struct OwnedImportStore: ImportMeetingStore {
    let store: MeetingStore
    let job: ProcessingJob
    let owner: String
    let copy: AudioImportCopy
    let now: @Sendable () -> Date

    func installImportedMeeting(
        _ meeting: Meeting, speakers: [Speaker], segments: [TranscriptSegment]
    ) async throws -> Int {
        try Task.checkCancellation()
        guard let end = meeting.endedAt else { throw AudioImportFileError.invalidOwnedCopy }
        let result = try await store.completeAudioImport(
            job.id, owner: owner,
            artifact: TranscriptionArtifact(
                meetingID: meeting.id, inputFingerprint: job.inputFingerprint, sourceTranscriptRevision: 0,
                language: meeting.language, speakers: speakers, segments: segments),
            audioDuration: end.timeIntervalSince(meeting.startedAt), audioDigest: copy.digest, at: now())
        return result.artifactVersion
    }

    func saveImportedSummary(_ draft: SummaryDraft, generationRun: GenerationRun) async throws {
        _ = try await store.saveSummary(draft, generationRun: generationRun)
    }

    func saveImportedSummaryRun(_ run: GenerationRun) async throws {
        try await store.saveGenerationRun(run)
    }
}
