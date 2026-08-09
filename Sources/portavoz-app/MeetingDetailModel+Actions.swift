import ApplicationKit
import Foundation
import PortavozCore

extension MeetingDetailModel {
    enum CommitmentAction {
        case confirm(ConfirmMeetingCommitmentRequest)
        case review(ReviewMeetingCommitmentRequest)
    }

    enum ContentAction {
        case renameMeeting(Meeting, title: String)
        case acceptNameSuggestion(Speaker, name: String)
        case acceptVoiceSuggestion(Speaker, name: String)
        case renameSpeaker(Speaker, name: String)
        case correctTranscript(CorrectMeetingTranscriptRequest)
        case restructureTranscript(RestructureMeetingTranscriptRequest)
        case findCanonicalPeople(Speaker, source: PersonAliasSource)
        case linkCanonicalPerson(
            Speaker,
            source: PersonAliasSource,
            selection: CanonicalPersonSelection)
        case setActionItem(UUID, done: Bool)
        case commitment(CommitmentAction)
        case setSummaryClaimFeedback(SummaryClaimID, SummaryClaimFeedback?)
        case removeCompanionCard(UUID)
        case confirmDecision(ConfirmDecisionAboutTopicRequest)
        case retractDecisionTopic(DecisionTopicLinkRetraction)
        case performSkill(
            MeetingSkillOffer,
            preview: MeetingSkillPreview,
            destination: String?)
        case dismissSkillOffer(MeetingSkillOffer)
    }

    enum ReviewAction {
        case deleteMeeting
        case retryProcessing
        case prepareDocument(MeetingDocumentFormat, MeetingDocumentOptions)
        case publishGist(MeetingDocumentOptions)
        case loadNameSuggestions
        case loadVoiceSuggestions
        case loadMetadataSuggestions
        case loadPlayback
        case compressAudio
        case exportAudioClip(ClosedRange<TimeInterval>, to: URL)
        case checkVoiceMemoryOffer(name: String)
        case rememberVoice(SpeakerID)
        case loadDecisionConfirmations
        case loadSkillOffers
    }

    enum Action {
        case content(ContentAction)
        case review(ReviewAction)
        case searchableContentChanged

        static func renameMeeting(_ meeting: Meeting, title: String) -> Self {
            .content(.renameMeeting(meeting, title: title))
        }

        static func acceptNameSuggestion(_ speaker: Speaker, name: String) -> Self {
            .content(.acceptNameSuggestion(speaker, name: name))
        }

        static func acceptVoiceSuggestion(_ speaker: Speaker, name: String) -> Self {
            .content(.acceptVoiceSuggestion(speaker, name: name))
        }

        static func renameSpeaker(_ speaker: Speaker, name: String) -> Self {
            .content(.renameSpeaker(speaker, name: name))
        }

        static func correctTranscript(
            _ request: CorrectMeetingTranscriptRequest
        ) -> Self {
            .content(.correctTranscript(request))
        }

        static func restructureTranscript(
            _ request: RestructureMeetingTranscriptRequest
        ) -> Self {
            .content(.restructureTranscript(request))
        }

        static func findCanonicalPeople(
            _ speaker: Speaker,
            source: PersonAliasSource
        ) -> Self {
            .content(.findCanonicalPeople(speaker, source: source))
        }

        static func linkCanonicalPerson(
            _ speaker: Speaker,
            source: PersonAliasSource,
            selection: CanonicalPersonSelection
        ) -> Self {
            .content(.linkCanonicalPerson(
                speaker,
                source: source,
                selection: selection))
        }

        static func setActionItem(_ id: UUID, done: Bool) -> Self {
            .content(.setActionItem(id, done: done))
        }

        static func confirmCommitment(
            _ request: ConfirmMeetingCommitmentRequest
        ) -> Self {
            .content(.commitment(.confirm(request)))
        }

        static func reviewCommitment(
            _ request: ReviewMeetingCommitmentRequest
        ) -> Self {
            .content(.commitment(.review(request)))
        }

        static func setSummaryClaimFeedback(
            _ claimID: SummaryClaimID,
            _ feedback: SummaryClaimFeedback?
        ) -> Self {
            .content(.setSummaryClaimFeedback(claimID, feedback))
        }

        static func removeCompanionCard(_ id: UUID) -> Self {
            .content(.removeCompanionCard(id))
        }

        static func confirmDecision(
            _ request: ConfirmDecisionAboutTopicRequest
        ) -> Self {
            .content(.confirmDecision(request))
        }

        static func retractDecisionTopic(
            _ retraction: DecisionTopicLinkRetraction
        ) -> Self {
            .content(.retractDecisionTopic(retraction))
        }

        static func performSkill(
            _ offer: MeetingSkillOffer,
            preview: MeetingSkillPreview,
            destination: String?
        ) -> Self {
            .content(.performSkill(
                offer,
                preview: preview,
                destination: destination))
        }

        static func dismissSkillOffer(_ offer: MeetingSkillOffer) -> Self {
            .content(.dismissSkillOffer(offer))
        }

        static var loadSkillOffers: Self {
            .review(.loadSkillOffers)
        }

        static var loadDecisionConfirmations: Self {
            .review(.loadDecisionConfirmations)
        }

        static var deleteMeeting: Self { .review(.deleteMeeting) }
        static var retryProcessing: Self { .review(.retryProcessing) }

        static func prepareDocument(
            _ format: MeetingDocumentFormat,
            options: MeetingDocumentOptions = MeetingDocumentOptions()
        ) -> Self {
            .review(.prepareDocument(format, options))
        }

        static func publishGist(
            options: MeetingDocumentOptions = MeetingDocumentOptions()
        ) -> Self {
            .review(.publishGist(options))
        }

        static var publishGist: Self {
            .review(.publishGist(MeetingDocumentOptions()))
        }
        static var loadNameSuggestions: Self { .review(.loadNameSuggestions) }
        static var loadVoiceSuggestions: Self { .review(.loadVoiceSuggestions) }
        static var loadMetadataSuggestions: Self { .review(.loadMetadataSuggestions) }
        static var loadPlayback: Self { .review(.loadPlayback) }
        static var compressAudio: Self { .review(.compressAudio) }

        static func exportAudioClip(
            _ range: ClosedRange<TimeInterval>,
            to destination: URL
        ) -> Self {
            .review(.exportAudioClip(range, to: destination))
        }

        static func checkVoiceMemoryOffer(name: String) -> Self {
            .review(.checkVoiceMemoryOffer(name: name))
        }

        static func rememberVoice(_ speakerID: SpeakerID) -> Self {
            .review(.rememberVoice(speakerID))
        }
    }

    enum Effect {
        case nameSuggestionAccepted(Speaker)
        case voiceSuggestionAccepted(Speaker)
        case speakerRenamed(Speaker)
        case transcriptCorrected(CorrectMeetingTranscriptResult)
        case transcriptRestructured(RestructureMeetingTranscriptResult)
        case canonicalPeopleFound(Speaker, PersonAliasSource, [Person])
        case canonicalPersonLinked(ConfirmedPersonLink)
        case commitmentConfirmed(Commitment)
        case commitmentReviewSaved
        case summaryClaimFeedbackSaved(SummaryClaimID)
        case decisionConfirmed(DecisionAboutTopicOutcome)
        case skillPerformed(MeetingSkillOffer)
        case meetingDeleted(MeetingID)
        case documentPrepared(PreparedMeetingDocument)
        case gistPublished(URL)
        case nameSuggestionsLoaded
        case voiceMemoryOfferChecked(Bool)
        case voiceRemembered
        case voiceMemoryInsufficientAudio
        case audioCompressed(Int64)
        case audioClipExported(URL)
        case operationFailed(String)
    }

}
