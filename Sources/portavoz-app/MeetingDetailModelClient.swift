import ApplicationKit
import Foundation
import PortavozCore

enum MeetingDetailSkillExecutionResult: Equatable, Sendable {
    case succeeded(outputURL: URL?)
    case retryableFailure(String)
    /// A remote mutation may have completed. Automatic and in-sheet retry are
    /// both forbidden; an optional URL is only available when the provider
    /// responded before local settlement failed.
    case outcomeUnknown(message: String, outputURL: URL?)
}

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
    func correctMeetingDetailTranscript(
        _ request: CorrectMeetingTranscriptRequest
    ) async throws -> CorrectMeetingTranscriptResult
    func restructureMeetingDetailTranscript(
        _ request: RestructureMeetingTranscriptRequest
    ) async throws -> RestructureMeetingTranscriptResult
    func findMeetingDetailPeople(matchingAlias alias: String) async throws -> [Person]
    func linkMeetingDetailSpeaker(
        _ request: LinkObservedSpeakerRequest
    ) async throws -> ConfirmedPersonLink
    func setMeetingDetailActionItem(_ id: UUID, done: Bool) async throws
    func confirmMeetingDetailCommitment(
        _ request: ConfirmMeetingCommitmentRequest
    ) async throws -> Commitment
    func reviewMeetingDetailCommitment(
        _ request: ReviewMeetingCommitmentRequest
    ) async throws
    func setMeetingDetailSummaryClaimFeedback(
        _ feedback: SummaryClaimFeedback?,
        for claimID: SummaryClaimID,
        meetingID: MeetingID
    ) async throws
    func confirmMeetingDetailDecision(
        _ request: ConfirmDecisionAboutTopicRequest
    ) async throws -> DecisionAboutTopicOutcome
    func retractMeetingDetailDecisionTopic(
        _ retraction: DecisionTopicLinkRetraction
    ) async throws
    func meetingDetailDecisionConfirmations(
        for observationIDs: [SummaryDecisionID]
    ) async throws -> [DecisionObservationConfirmationState]
    func meetingDetailLinkableTopics() async throws -> [LinkableTopic]
    func meetingDetailSkillOffers(
        meetingID: MeetingID,
        hasSummary: Bool
    ) async throws -> [MeetingSkillOffer]
    func meetingDetailSkillReceipts(
        meetingID: MeetingID
    ) async throws -> [MeetingSkillReceipt]
    func meetingDetailSkillPreview(
        _ offer: MeetingSkillOffer,
        destination: String?
    ) async throws -> MeetingSkillPreview
    func performMeetingDetailSkill(
        _ offer: MeetingSkillOffer,
        proposalID: UUID,
        proposedAt: Date,
        preview: MeetingSkillPreview,
        destination: String?
    ) async throws -> MeetingDetailSkillExecutionResult
    func prepareMeetingDetailGitHubIssueDraft(
        _ request: PrepareGitHubIssueDraftRequest
    ) async throws -> GitHubIssueDraft
    func performMeetingDetailGitHubIssue(
        _ draft: GitHubIssueDraft,
        proposalID: UUID,
        proposedAt: Date
    ) async throws -> MeetingDetailSkillExecutionResult
    func dismissMeetingDetailSkillOffer(_ offer: MeetingSkillOffer) async throws
    func deleteMeetingDetailCompanionCard(_ id: UUID) async throws
    func deleteMeetingDetail(_ id: MeetingID) async throws
    func retryMeetingDetailProcessing(_ meetingID: MeetingID) async throws
    func prepareMeetingDetailDocument(
        _ meetingID: MeetingID,
        format: MeetingDocumentFormat,
        options: MeetingDocumentOptions
    ) async throws -> PreparedMeetingDocument
    func publishMeetingDetailGist(
        _ meetingID: MeetingID,
        options: MeetingDocumentOptions
    ) async throws -> URL
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
    func requestMeetingDetailMemoryGraphReindex()
}
