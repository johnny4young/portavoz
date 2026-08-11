import ApplicationKit
import Foundation
import PortavozCore

extension MeetingDetailModel {
    struct SkillExecutionContext {
        let proposalID: UUID
        let proposedAt: Date
        let preview: MeetingSkillPreview
        let destination: String?
    }

    enum CommitmentAction {
        case confirm(ConfirmMeetingCommitmentRequest)
        case review(ReviewMeetingCommitmentRequest)
    }

    enum EditingAction {
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
    }

    enum ArtifactAction {
        case setActionItem(UUID, done: Bool)
        case commitment(CommitmentAction)
        case setSummaryClaimFeedback(SummaryClaimID, SummaryClaimFeedback?)
        case removeCompanionCard(UUID)
        case confirmDecision(ConfirmDecisionAboutTopicRequest)
        case retractDecisionTopic(DecisionTopicLinkRetraction)
        case performSkill(MeetingSkillOffer, SkillExecutionContext)
        case dismissSkillOffer(MeetingSkillOffer)
    }

    enum ContentAction {
        case editing(EditingAction)
        case artifact(ArtifactAction)
    }

    enum MaintenanceAction {
        case deleteMeeting
        case retryProcessing
    }

    enum PreparationAction {
        case prepareDocument(MeetingDocumentFormat, MeetingDocumentOptions)
        case publishGist(MeetingDocumentOptions)
        case loadNameSuggestions
        case loadVoiceSuggestions
        case loadMetadataSuggestions
        case loadDecisionConfirmations
        case loadSkillOffers
    }

    enum AudioAction {
        case loadPlayback
        case compressAudio
        case exportAudioClip(ClosedRange<TimeInterval>, to: URL)
        case checkVoiceMemoryOffer(name: String)
        case rememberVoice(SpeakerID)
    }

    enum ReviewAction {
        case maintenance(MaintenanceAction)
        case preparation(PreparationAction)
        case audio(AudioAction)
    }

    enum Action {
        case content(ContentAction)
        case review(ReviewAction)
        case searchableContentChanged

        static func renameMeeting(_ meeting: Meeting, title: String) -> Self {
            .content(.editing(.renameMeeting(meeting, title: title)))
        }

        static func acceptNameSuggestion(_ speaker: Speaker, name: String) -> Self {
            .content(.editing(.acceptNameSuggestion(speaker, name: name)))
        }

        static func acceptVoiceSuggestion(_ speaker: Speaker, name: String) -> Self {
            .content(.editing(.acceptVoiceSuggestion(speaker, name: name)))
        }

        static func renameSpeaker(_ speaker: Speaker, name: String) -> Self {
            .content(.editing(.renameSpeaker(speaker, name: name)))
        }

        static func correctTranscript(
            _ request: CorrectMeetingTranscriptRequest
        ) -> Self {
            .content(.editing(.correctTranscript(request)))
        }

        static func restructureTranscript(
            _ request: RestructureMeetingTranscriptRequest
        ) -> Self {
            .content(.editing(.restructureTranscript(request)))
        }

        static func findCanonicalPeople(
            _ speaker: Speaker,
            source: PersonAliasSource
        ) -> Self {
            .content(.editing(.findCanonicalPeople(speaker, source: source)))
        }

        static func linkCanonicalPerson(
            _ speaker: Speaker,
            source: PersonAliasSource,
            selection: CanonicalPersonSelection
        ) -> Self {
            .content(.editing(.linkCanonicalPerson(
                speaker,
                source: source,
                selection: selection)))
        }

        static func setActionItem(_ id: UUID, done: Bool) -> Self {
            .content(.artifact(.setActionItem(id, done: done)))
        }

        static func confirmCommitment(
            _ request: ConfirmMeetingCommitmentRequest
        ) -> Self {
            .content(.artifact(.commitment(.confirm(request))))
        }

        static func reviewCommitment(
            _ request: ReviewMeetingCommitmentRequest
        ) -> Self {
            .content(.artifact(.commitment(.review(request))))
        }

        static func setSummaryClaimFeedback(
            _ claimID: SummaryClaimID,
            _ feedback: SummaryClaimFeedback?
        ) -> Self {
            .content(.artifact(.setSummaryClaimFeedback(claimID, feedback)))
        }

        static func removeCompanionCard(_ id: UUID) -> Self {
            .content(.artifact(.removeCompanionCard(id)))
        }

        static func confirmDecision(
            _ request: ConfirmDecisionAboutTopicRequest
        ) -> Self {
            .content(.artifact(.confirmDecision(request)))
        }

        static func retractDecisionTopic(
            _ retraction: DecisionTopicLinkRetraction
        ) -> Self {
            .content(.artifact(.retractDecisionTopic(retraction)))
        }

        static func performSkill(
            _ offer: MeetingSkillOffer,
            proposalID: UUID,
            proposedAt: Date,
            preview: MeetingSkillPreview,
            destination: String?
        ) -> Self {
            .content(.artifact(.performSkill(
                offer,
                SkillExecutionContext(
                    proposalID: proposalID,
                    proposedAt: proposedAt,
                    preview: preview,
                    destination: destination))))
        }

        static func dismissSkillOffer(_ offer: MeetingSkillOffer) -> Self {
            .content(.artifact(.dismissSkillOffer(offer)))
        }

        static var loadSkillOffers: Self {
            .review(.preparation(.loadSkillOffers))
        }

        static var loadDecisionConfirmations: Self {
            .review(.preparation(.loadDecisionConfirmations))
        }

        static var deleteMeeting: Self { .review(.maintenance(.deleteMeeting)) }
        static var retryProcessing: Self { .review(.maintenance(.retryProcessing)) }

        static func prepareDocument(
            _ format: MeetingDocumentFormat,
            options: MeetingDocumentOptions = MeetingDocumentOptions()
        ) -> Self {
            .review(.preparation(.prepareDocument(format, options)))
        }

        static func publishGist(
            options: MeetingDocumentOptions = MeetingDocumentOptions()
        ) -> Self {
            .review(.preparation(.publishGist(options)))
        }

        static var publishGist: Self {
            .review(.preparation(.publishGist(MeetingDocumentOptions())))
        }
        static var loadNameSuggestions: Self {
            .review(.preparation(.loadNameSuggestions))
        }
        static var loadVoiceSuggestions: Self {
            .review(.preparation(.loadVoiceSuggestions))
        }
        static var loadMetadataSuggestions: Self {
            .review(.preparation(.loadMetadataSuggestions))
        }
        static var loadPlayback: Self { .review(.audio(.loadPlayback)) }
        static var compressAudio: Self { .review(.audio(.compressAudio)) }

        static func exportAudioClip(
            _ range: ClosedRange<TimeInterval>,
            to destination: URL
        ) -> Self {
            .review(.audio(.exportAudioClip(range, to: destination)))
        }

        static func checkVoiceMemoryOffer(name: String) -> Self {
            .review(.audio(.checkVoiceMemoryOffer(name: name)))
        }

        static func rememberVoice(_ speakerID: SpeakerID) -> Self {
            .review(.audio(.rememberVoice(speakerID)))
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
        case skillPerformed(MeetingSkillOffer, outputURL: URL?)
        case skillOutcomeUnknown(
            MeetingSkillOffer,
            message: String,
            outputURL: URL?)
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
