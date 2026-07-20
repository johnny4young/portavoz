import ApplicationKit
import Foundation
import PortavozCore

/// Narrow read/write contract for one Meeting Detail feature instance.
/// Platform capabilities stay behind `AppServices`; the model sees only
/// application requests, read projections, and typed results.
@MainActor
protocol MeetingDetailModelClient: AnyObject {
    func observeMeetingReview(
        _ meetingID: MeetingID
    ) -> AsyncStream<MeetingReviewUpdate>

    func renameMeetingDetailMeeting(_ meeting: Meeting) async throws
    func renameMeetingDetailSpeaker(_ speaker: Speaker) async throws
    func findMeetingDetailPeople(matchingAlias alias: String) async throws -> [Person]
    func linkMeetingDetailSpeaker(
        _ request: LinkObservedSpeakerRequest
    ) async throws -> ConfirmedPersonLink
    func setMeetingDetailActionItem(_ id: UUID, done: Bool) async throws
    func setMeetingDetailSummaryClaimFeedback(
        _ feedback: SummaryClaimFeedback?,
        for claimID: SummaryClaimID,
        meetingID: MeetingID
    ) async throws
    func deleteMeetingDetailCompanionCard(_ id: UUID) async throws
    func deleteMeetingDetail(_ id: MeetingID) async throws
    func retryMeetingDetailProcessing(_ meetingID: MeetingID) async throws
    func prepareMeetingDetailDocument(
        _ meetingID: MeetingID,
        format: MeetingDocumentFormat
    ) async throws -> PreparedMeetingDocument
    func publishMeetingDetailGist(_ meetingID: MeetingID) async throws -> URL
    func meetingDetailNameSuggestions(
        _ meetingID: MeetingID
    ) async throws -> [MeetingNameSuggestion]
    func meetingDetailVoiceSuggestions(
        _ meetingID: MeetingID
    ) async throws -> [MeetingVoiceSuggestion]
    func meetingDetailMetadataSuggestions(
        _ request: SuggestMeetingReviewMetadataRequest
    ) async throws -> MeetingReviewMetadataSuggestions
    func prepareMeetingDetailPlayback(
        _ request: PrepareMeetingPlaybackRequest
    ) async throws -> PreparedMeetingPlayback?
    func compressMeetingDetailAudio(
        _ request: CompressMeetingAudioRequest
    ) async throws -> MeetingAudioCompressionResult
    func exportMeetingDetailAudioClip(
        _ request: ExportMeetingAudioClipRequest
    ) async throws
    func canRememberMeetingDetailVoice(named name: String) async -> Bool
    func rememberMeetingDetailVoice(
        meetingID: MeetingID,
        speakerID: SpeakerID
    ) async throws -> ManageMeetingVoiceMemoryResult
    func requestMeetingDetailSearchReindex()
}
