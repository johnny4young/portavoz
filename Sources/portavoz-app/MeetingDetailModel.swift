import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// Per-detail owner of scoped loading, partial failure, and the current
/// storage-independent meeting review projection.
@MainActor
@Observable
final class MeetingDetailModel {
    typealias LoadPhase = MeetingDetailLoadPhase

    struct State {
        fileprivate(set) var phase: LoadPhase = .idle
        fileprivate(set) var readModel: MeetingReviewReadModel?
        fileprivate(set) var nameSuggestions: [MeetingNameSuggestion] = []
        fileprivate(set) var isSuggestingNames = false
        fileprivate(set) var voiceSuggestions: [MeetingVoiceSuggestion] = []
        fileprivate(set) var chapterTitles: [TimeInterval: String] = [:]
        fileprivate(set) var suggestedTitle: String?
        fileprivate(set) var suggestedRecipe: Recipe?
        fileprivate(set) var dismissedThinSummaryVersion: Int?
        fileprivate(set) var playback: PreparedMeetingPlayback?
        fileprivate(set) var isCompressingAudio = false
        fileprivate(set) var audioCompressionMessage: String?
        fileprivate(set) var revision = 0
        fileprivate(set) var lastActionError: String?
        fileprivate(set) var decisionConfirmations:
            [SummaryDecisionID: DecisionObservationConfirmationState] = [:]
        fileprivate(set) var linkableTopics: [LinkableTopic] = []
        fileprivate(set) var skillOffers: [MeetingSkillOffer] = []
        fileprivate(set) var skillReceipts: [MeetingSkillReceipt] = []
    }

    private(set) var state = State()
    let meetingID: MeetingID

    private let client: any MeetingDetailModelClient
    private let firstContentTrace: MeetingDetailFirstContentTrace
    private var reviewAccumulator = MeetingDetailReviewAccumulator()
    private var metadataSuggestionState = MeetingDetailMetadataSuggestionState()
    private var didLoadVoiceSuggestions = false
    private var playbackDirectoryAttempt: String?

    init(
        meetingID: MeetingID,
        client: any MeetingDetailModelClient,
        workloadTelemetry: ResourceWorkloadTelemetry = .disabled
    ) {
        self.meetingID = meetingID
        self.client = client
        firstContentTrace = MeetingDetailFirstContentTrace(
            workloadTelemetry: workloadTelemetry)
    }

    /// Ends the content-free navigation interval when SwiftUI mounts the
    /// first real Meeting Detail projection. Repeated appearances are ignored.
    func firstContentDidAppear() {
        firstContentTrace.finish()
    }

    /// Any explicit summary regeneration supersedes the optional recipe chip.
    func dismissSuggestedRecipe() {
        state.suggestedRecipe = nil
    }

    func dismissSuggestedTitle() {
        state.suggestedTitle = nil
    }

    func dismissNameSuggestion(label: String) {
        state.nameSuggestions.removeAll { $0.label == label }
    }

    func dismissVoiceSuggestion(speakerLabel: String) {
        state.voiceSuggestions.removeAll { $0.speakerLabel == speakerLabel }
    }

    func dismissThinSummarySuggestion(version: Int) {
        state.dismissedThinSummaryVersion = version
    }

    /// The route owns the AVFoundation observer lifetime. Leaving the detail
    /// invalidates the application playback facade and allows a clean reload
    /// if this route instance appears again.
    func invalidatePlayback() {
        state.playback?.session.invalidate()
        state.playback = nil
        playbackDirectoryAttempt = nil
    }

    func observe() async {
        let currentID = reviewAccumulator.beginObservation()
        state.phase = .loading

        for await update in client.observeMeetingReview(meetingID) {
            guard !Task.isCancelled,
                reviewAccumulator.accepts(observationID: currentID)
            else { return }
            publish(update)
        }
    }

    @discardableResult
    func send(_ action: Action) async -> Effect? {
        switch action {
        case .content(let contentAction):
            return await sendContentAction(contentAction)
        case .review(let reviewAction):
            return await sendReviewAction(reviewAction)
        case .searchableContentChanged:
            client.requestMeetingDetailSearchReindex()
            return nil
        }
    }

    private func sendContentAction(_ action: ContentAction) async -> Effect? {
        switch action {
        case .editing(let editingAction):
            return await sendEditingAction(editingAction)
        case .artifact(let artifactAction):
            return await sendArtifactAction(artifactAction)
        }
    }

    private func sendEditingAction(_ action: EditingAction) async -> Effect? {
        switch action {
        case .renameMeeting(let meeting, let title):
            await renameMeeting(meeting, title: title)
            return nil
        case .acceptNameSuggestion(let speaker, let name):
            return await acceptNameSuggestion(speaker, name: name)
        case .acceptVoiceSuggestion(let speaker, let name):
            return await acceptVoiceSuggestion(speaker, name: name)
        case .renameSpeaker(let speaker, let name):
            return await renameSpeaker(speaker, name: name)
        case .correctTranscript(let request):
            return await correctTranscript(request)
        case .restructureTranscript(let request):
            return await restructureTranscript(request)
        case .findCanonicalPeople(let speaker, let source):
            return await findCanonicalPeople(speaker, source: source)
        case .linkCanonicalPerson(let speaker, let source, let selection):
            return await linkCanonicalPerson(
                speaker,
                source: source,
                selection: selection)
        }
    }

    private func sendArtifactAction(_ action: ArtifactAction) async -> Effect? {
        switch action {
        case .setActionItem(let id, let done):
            await setActionItem(id, done: done)
            return nil
        case .commitment(let commitmentAction):
            return await sendCommitmentAction(commitmentAction)
        case .setSummaryClaimFeedback(let claimID, let feedback):
            return await setSummaryClaimFeedback(feedback, for: claimID)
        case .removeCompanionCard(let id):
            await removeCompanionCard(id)
            return nil
        case .confirmDecision(let request):
            return await confirmDecision(request)
        case .retractDecisionTopic(let retraction):
            await retractDecisionTopic(retraction)
            return nil
        case .performSkill(let offer, let context):
            return await performSkill(offer, context: context)
        case .dismissSkillOffer(let offer):
            await dismissSkillOffer(offer)
            return nil
        }
    }

    private func sendCommitmentAction(_ action: CommitmentAction) async -> Effect? {
        switch action {
        case .confirm(let request):
            return await confirmCommitment(request)
        case .review(let request):
            return await reviewCommitment(request)
        }
    }

    private func sendReviewAction(_ action: ReviewAction) async -> Effect? {
        switch action {
        case .maintenance(let maintenanceAction):
            return await sendMaintenanceAction(maintenanceAction)
        case .preparation(let preparationAction):
            return await sendPreparationAction(preparationAction)
        case .audio(let audioAction):
            return await sendAudioAction(audioAction)
        }
    }

    private func sendMaintenanceAction(_ action: MaintenanceAction) async -> Effect? {
        switch action {
        case .deleteMeeting:
            await deleteMeeting()
            return .meetingDeleted(meetingID)
        case .retryProcessing:
            await retryProcessing()
            return nil
        }
    }

    private func sendPreparationAction(_ action: PreparationAction) async -> Effect? {
        switch action {
        case .prepareDocument(let format, let options):
            return await prepareDocument(format, options: options)
        case .publishGist(let options):
            return await publishGist(options: options)
        case .loadNameSuggestions:
            return await loadNameSuggestions()
        case .loadVoiceSuggestions:
            await loadVoiceSuggestions()
            return nil
        case .loadMetadataSuggestions:
            await loadMetadataSuggestions()
            return nil
        case .loadDecisionConfirmations:
            await loadDecisionConfirmations()
            return nil
        case .loadSkillOffers:
            await loadSkillOffers()
            return nil
        }
    }

    private func sendAudioAction(_ action: AudioAction) async -> Effect? {
        switch action {
        case .loadPlayback:
            await loadPlayback()
            return nil
        case .compressAudio:
            return await compressAudio()
        case .exportAudioClip(let range, let destination):
            return await exportAudioClip(range, to: destination)
        case .checkVoiceMemoryOffer(let name):
            return .voiceMemoryOfferChecked(
                await client.canRememberMeetingDetailVoice(named: name))
        case .rememberVoice(let speakerID):
            return await rememberVoice(speakerID)
        }
    }
}

private extension MeetingDetailModel {
    func renameMeeting(_ original: Meeting, title: String) async {
        var meeting = original
        meeting.title = title
        do {
            try await client.renameMeetingDetailMeeting(meeting)
        } catch {
            state.lastActionError = L10n.format(
                "Could not rename: %@",
                error.localizedDescription)
            return
        }
        state.lastActionError = nil
        state.suggestedTitle = nil
        client.requestMeetingDetailSearchReindex()
    }

    func acceptNameSuggestion(_ original: Speaker, name: String) async -> Effect {
        var speaker = original
        speaker.displayName = name
        do {
            try await client.renameMeetingDetailSpeaker(speaker)
        } catch {
            let message = L10n.text("Could not apply this name suggestion.")
            state.lastActionError = message
            return .operationFailed(message)
        }
        state.lastActionError = nil
        state.nameSuggestions.removeAll { $0.label == original.label }
        client.requestMeetingDetailSearchReindex()
        return .nameSuggestionAccepted(speaker)
    }

    func acceptVoiceSuggestion(_ original: Speaker, name: String) async -> Effect {
        var speaker = original
        speaker.displayName = name
        do {
            try await client.renameMeetingDetailSpeaker(speaker)
        } catch {
            let message = L10n.text("Could not apply this voice suggestion.")
            state.lastActionError = message
            return .operationFailed(message)
        }
        state.lastActionError = nil
        state.voiceSuggestions.removeAll { $0.speakerLabel == original.label }
        client.requestMeetingDetailSearchReindex()
        return .voiceSuggestionAccepted(speaker)
    }

    func renameSpeaker(_ original: Speaker, name: String) async -> Effect? {
        var speaker = original
        speaker.displayName = name.isEmpty ? nil : name
        do {
            try await client.renameMeetingDetailSpeaker(speaker)
        } catch {
            state.lastActionError = L10n.format(
                "Could not rename: %@",
                error.localizedDescription)
            return nil
        }
        client.requestMeetingDetailSearchReindex()
        return .speakerRenamed(speaker)
    }

    func correctTranscript(
        _ request: CorrectMeetingTranscriptRequest
    ) async -> Effect {
        do {
            let result = try await client.correctMeetingDetailTranscript(request)
            state.lastActionError = nil
            client.requestMeetingDetailSearchReindex()
            return .transcriptCorrected(result)
        } catch {
            let message = L10n.format(
                "Could not save this transcript correction: %@",
                TranscriptCorrectionErrorMessages.describe(error))
            state.lastActionError = message
            return .operationFailed(message)
        }
    }

    func restructureTranscript(
        _ request: RestructureMeetingTranscriptRequest
    ) async -> Effect {
        do {
            let result = try await client.restructureMeetingDetailTranscript(request)
            state.lastActionError = nil
            client.requestMeetingDetailSearchReindex()
            return .transcriptRestructured(result)
        } catch {
            let message = L10n.format(
                "Could not save this transcript correction: %@",
                TranscriptCorrectionErrorMessages.describe(error))
            state.lastActionError = message
            return .operationFailed(message)
        }
    }

    func findCanonicalPeople(
        _ speaker: Speaker,
        source: PersonAliasSource
    ) async -> Effect? {
        guard let name = speaker.displayName else { return nil }
        do {
            let people = try await client.findMeetingDetailPeople(matchingAlias: name)
            state.lastActionError = nil
            return .canonicalPeopleFound(speaker, source, people)
        } catch {
            state.lastActionError = L10n.text("Could not look up remembered people.")
            return nil
        }
    }

    func linkCanonicalPerson(
        _ speaker: Speaker,
        source: PersonAliasSource,
        selection: CanonicalPersonSelection
    ) async -> Effect? {
        guard let name = speaker.displayName else { return nil }
        do {
            let link = try await client.linkMeetingDetailSpeaker(
                LinkObservedSpeakerRequest(
                    speakerID: speaker.id,
                    observedName: name,
                    source: source,
                    selection: selection))
            state.lastActionError = nil
            client.requestMeetingDetailSearchReindex()
            return .canonicalPersonLinked(link)
        } catch {
            state.lastActionError = L10n.text("Could not remember this person.")
            return nil
        }
    }

    func setActionItem(_ id: UUID, done: Bool) async {
        _ = try? await client.setMeetingDetailActionItem(id, done: done)
        client.requestMeetingDetailSearchReindex()
    }

    func confirmCommitment(
        _ request: ConfirmMeetingCommitmentRequest
    ) async -> Effect? {
        do {
            let commitment = try await client.confirmMeetingDetailCommitment(request)
            state.lastActionError = nil
            client.requestMeetingDetailSearchReindex()
            client.requestMeetingDetailMemoryGraphReindex()
            return .commitmentConfirmed(commitment)
        } catch {
            state.lastActionError = L10n.text(
                "Could not confirm this commitment. Its source may have changed.")
            return nil
        }
    }

    func reviewCommitment(
        _ request: ReviewMeetingCommitmentRequest
    ) async -> Effect? {
        do {
            try await client.reviewMeetingDetailCommitment(request)
            state.lastActionError = nil
            return .commitmentReviewSaved
        } catch {
            state.lastActionError = L10n.text(
                "Could not update this commitment review. Its source may have changed.")
            return nil
        }
    }

    func setSummaryClaimFeedback(
        _ feedback: SummaryClaimFeedback?,
        for claimID: SummaryClaimID
    ) async -> Effect? {
        do {
            try await client.setMeetingDetailSummaryClaimFeedback(
                feedback,
                for: claimID,
                meetingID: meetingID)
            state.lastActionError = nil
            return .summaryClaimFeedbackSaved(claimID)
        } catch {
            state.lastActionError = L10n.text(
                "Could not save this summary feedback. The summary may have changed.")
            return nil
        }
    }

    /// Which generated decisions already became durable truth, and the
    /// topics they are about — what the confirm affordance renders from.
    func loadDecisionConfirmations() async {
        guard let observationIDs = state.readModel?.summary?
            .draft.decisionEvidence.map(\.id),
            !observationIDs.isEmpty
        else { return }
        do {
            let states = try await client.meetingDetailDecisionConfirmations(
                for: observationIDs)
            state.decisionConfirmations = Dictionary(
                uniqueKeysWithValues: states.map { ($0.observationID, $0) })
            state.linkableTopics = try await client.meetingDetailLinkableTopics()
        } catch {
            // Presentation only; the affordance simply stays in its
            // unconfirmed reading until a later load succeeds.
        }
    }

    func confirmDecision(
        _ request: ConfirmDecisionAboutTopicRequest
    ) async -> Effect? {
        do {
            let outcome = try await client.confirmMeetingDetailDecision(request)
            state.lastActionError = nil
            await loadDecisionConfirmations()
            return .decisionConfirmed(outcome)
        } catch is ConfirmDecisionAboutTopicError {
            state.lastActionError = L10n.text(
                "That topic name matches more than one topic. Pick one from the list.")
            return nil
        } catch {
            state.lastActionError = L10n.text(
                "Could not confirm this decision. Its summary may have changed.")
            return nil
        }
    }

    /// Which skills the banner may offer, and the receipts of what already
    /// ran — both read from durable state, never guessed.
    func loadSkillOffers() async {
        do {
            let hasSummary = state.readModel?.summary != nil
            state.skillOffers = try await client.meetingDetailSkillOffers(
                meetingID: meetingID,
                hasSummary: hasSummary)
            state.skillReceipts = try await client.meetingDetailSkillReceipts(
                meetingID: meetingID)
        } catch {
            // Presentation only: the banner simply stays empty until a later
            // load succeeds.
        }
    }

    /// Runs one confirmed offer and re-reads offers and receipts so the UI
    /// reflects the durable outcome. Returns the effect the sheet closes on.
    func performSkill(_ offer: MeetingSkillOffer, context: SkillExecutionContext) async -> Effect? {
        do {
            let result = try await client.performMeetingDetailSkill(
                offer, proposalID: context.proposalID,
                proposedAt: context.proposedAt, preview: context.preview,
                destination: context.destination)
            switch result {
            case .succeeded(let outputURL):
                state.lastActionError = nil
                await loadSkillOffers()
                return .skillPerformed(offer, outputURL: outputURL)
            case .retryableFailure(let message):
                state.lastActionError = message
                await loadSkillOffers()
                return nil
            case .outcomeUnknown(let message, let outputURL):
                state.lastActionError = nil
                await loadSkillOffers()
                return .skillOutcomeUnknown(offer, message: message, outputURL: outputURL)
            }
        } catch {
            state.lastActionError = offer.kind == .secretGistPublish
                ? UseCaseErrorMessages.describe(error)
                : L10n.text("The action could not run. Nothing left Portavoz.")
            return nil
        }
    }

    func dismissSkillOffer(_ offer: MeetingSkillOffer) async {
        do {
            try await client.dismissMeetingDetailSkillOffer(offer)
            await loadSkillOffers()
        } catch {
            state.lastActionError = L10n.text(
                "Could not dismiss this suggestion.")
        }
    }

    /// Withdraws one "about" link and re-reads the confirmations so the badge
    /// reflects durable truth, never an optimistic guess.
    func retractDecisionTopic(_ retraction: DecisionTopicLinkRetraction) async {
        do {
            try await client.retractMeetingDetailDecisionTopic(retraction)
            state.lastActionError = nil
            await loadDecisionConfirmations()
        } catch {
            state.lastActionError = L10n.text(
                "Could not remove this topic link. It may already be retracted.")
        }
    }

    func removeCompanionCard(_ id: UUID) async {
        do {
            try await client.deleteMeetingDetailCompanionCard(id)
        } catch {
            state.lastActionError = L10n.text("Could not remove the card.")
        }
    }

    func deleteMeeting() async {
        _ = try? await client.deleteMeetingDetail(meetingID)
        client.requestMeetingDetailSearchReindex()
    }

    func retryProcessing() async {
        do {
            try await client.retryMeetingDetailProcessing(meetingID)
            state.lastActionError = nil
        } catch {
            state.lastActionError = L10n.text(
                "Could not restart processing. Export a support file from Settings and try again.")
        }
    }

    func prepareDocument(
        _ format: MeetingDocumentFormat,
        options: MeetingDocumentOptions
    ) async -> Effect {
        do {
            return .documentPrepared(try await client.prepareMeetingDetailDocument(
                meetingID,
                format: format,
                options: options))
        } catch {
            return .operationFailed(UseCaseErrorMessages.describe(error))
        }
    }

    func publishGist(options: MeetingDocumentOptions) async -> Effect {
        do {
            return .gistPublished(try await client.publishMeetingDetailGist(
                meetingID,
                options: options))
        } catch {
            return .operationFailed(UseCaseErrorMessages.describe(error))
        }
    }

    func loadNameSuggestions() async -> Effect? {
        guard !state.isSuggestingNames else { return nil }
        state.isSuggestingNames = true
        defer { state.isSuggestingNames = false }
        do {
            state.nameSuggestions = try await client.meetingDetailNameSuggestions(meetingID)
            reconcileSuggestionSources()
            guard !state.nameSuggestions.isEmpty || !state.voiceSuggestions.isEmpty else {
                return .operationFailed(L10n.text(
                    "No verified name suggestions were found — you can rename the pills manually."))
            }
            state.lastActionError = nil
            return .nameSuggestionsLoaded
        } catch {
            return .operationFailed(L10n.text(error.localizedDescription))
        }
    }

    func loadVoiceSuggestions() async {
        guard !didLoadVoiceSuggestions else { return }
        didLoadVoiceSuggestions = true
        state.voiceSuggestions = (try? await client.meetingDetailVoiceSuggestions(
            meetingID)) ?? []
        reconcileSuggestionSources()
    }

    /// Voice evidence outranks a text proposal for the same speaker: the
    /// voiceprint match is deterministic, thresholded, and cross-meeting,
    /// while the text path crossed a language model. Two chips proposing
    /// different names for one speaker must never render together.
    private func reconcileSuggestionSources() {
        guard !state.voiceSuggestions.isEmpty else { return }
        let voiceLabels = Set(state.voiceSuggestions.map(\.speakerLabel))
        state.nameSuggestions.removeAll { voiceLabels.contains($0.label) }
    }

    func loadMetadataSuggestions() async {
        let titledStarts = Set(state.chapterTitles.keys)
        guard let detail = state.readModel,
            let attempt = metadataSuggestionState.begin(
                review: detail,
                titledChapterStarts: titledStarts)
        else { return }

        do {
            let suggestions = try await client.meetingDetailMetadataSuggestions(
                attempt.request)
            guard !Task.isCancelled,
                metadataSuggestionState.accepts(attempt)
            else { return }
            metadataSuggestionState.complete(attempt)
            if attempt.suggestsMeetingTitle {
                state.suggestedTitle = suggestions.meetingTitle
            }
            if attempt.suggestsRecipe {
                state.suggestedRecipe = suggestions.recipe
            }
            state.chapterTitles.merge(suggestions.chapterTitles) { _, new in new }
        } catch is CancellationError {
            // A newer read revision retries every still-eligible suggestion.
        } catch {
            guard metadataSuggestionState.accepts(attempt) else { return }
            // Optional intelligence degrades silently, as before. Mark only
            // the attempted one-shot suggestions complete to avoid a loop;
            // missing chapter labels may retry after a future read revision.
            metadataSuggestionState.complete(attempt)
        }
    }

    func loadPlayback() async {
        guard let detail = state.readModel,
            let relative = detail.meeting.audioDirectory,
            !relative.isEmpty
        else { return }
        guard state.playback == nil, playbackDirectoryAttempt != relative else { return }
        playbackDirectoryAttempt = relative

        do {
            let prepared = try await client.prepareMeetingDetailPlayback(
                PrepareMeetingPlaybackRequest(
                    relativeAudioDirectory: relative,
                    segments: detail.segments))
            guard !Task.isCancelled else {
                prepared?.session.invalidate()
                playbackDirectoryAttempt = nil
                return
            }
            state.playback = prepared
        } catch is CancellationError {
            playbackDirectoryAttempt = nil
        } catch {
            // Missing or unreadable optional audio preserves the released
            // text-only detail instead of hiding healthy transcript content.
        }
    }

    func compressAudio() async -> Effect? {
        guard !state.isCompressingAudio,
            state.playback?.canCompressAudio == true,
            let relative = state.readModel?.meeting.audioDirectory
        else { return nil }
        state.isCompressingAudio = true
        state.audioCompressionMessage = nil
        defer { state.isCompressingAudio = false }

        do {
            let result = try await client.compressMeetingDetailAudio(
                CompressMeetingAudioRequest(relativeAudioDirectory: relative))
            let previous = state.playback
            state.playback = nil
            playbackDirectoryAttempt = nil
            previous?.session.invalidate()
            await loadPlayback()
            let freed = ByteCountFormatter.string(
                fromByteCount: result.bytesFreed,
                countStyle: .file)
            state.audioCompressionMessage = L10n.format(
                "Audio compressed — %@ freed.",
                freed)
            return .audioCompressed(result.bytesFreed)
        } catch is CancellationError {
            return nil
        } catch {
            state.audioCompressionMessage = error.localizedDescription
            return .operationFailed(error.localizedDescription)
        }
    }

    func exportAudioClip(
        _ range: ClosedRange<TimeInterval>,
        to destination: URL
    ) async -> Effect {
        guard let relative = state.readModel?.meeting.audioDirectory else {
            return .operationFailed(L10n.text("The meeting has no audio to trim."))
        }
        do {
            try await client.exportMeetingDetailAudioClip(
                ExportMeetingAudioClipRequest(
                    relativeAudioDirectory: relative,
                    range: range,
                    destination: destination,
                    segments: state.readModel?.segments ?? [],
                    clearPlayback: state.playback?.session.clearPlayback ?? true))
            return .audioClipExported(destination)
        } catch {
            return .operationFailed(error.localizedDescription)
        }
    }

    func rememberVoice(_ speakerID: SpeakerID) async -> Effect {
        do {
            switch try await client.rememberMeetingDetailVoice(
                meetingID: meetingID,
                speakerID: speakerID) {
            case .remembered:
                return .voiceRemembered
            case .insufficientAudio:
                return .voiceMemoryInsufficientAudio
            case .suggestions, .canRemember:
                return .operationFailed(L10n.text("Could not remember the voice."))
            }
        } catch {
            return .operationFailed(L10n.format(
                "Could not remember the voice: %@",
                UseCaseErrorMessages.describe(error)))
        }
    }
}

extension MeetingDetailModel {
    /// The exact artifact one offer would produce — read-only, computed for
    /// the confirmation sheet before anything durable exists.
    func skillPreview(_ offer: MeetingSkillOffer, destination: String?) async -> MeetingSkillPreview? {
        do {
            return try await client.meetingDetailSkillPreview(
                offer,
                destination: destination)
        } catch {
            state.lastActionError = L10n.text(
                "Could not build this action's preview.")
            return nil
        }
    }
}

private extension MeetingDetailModel {
    func publish(_ update: MeetingReviewUpdate) {
        // Reject optional intelligence generated from an older projection.
        let transition = reviewAccumulator.apply(update)
        metadataSuggestionState.invalidate(correctionRevisionChanged: transition.correctionRevisionChanged)
        if transition.correctionRevisionChanged {
            state.chapterTitles = [:]
            state.suggestedTitle = nil
            state.suggestedRecipe = nil
        }
        if transition.shouldInvalidatePlayback {
            invalidatePlayback()
        }
        state.readModel = transition.readModel
        state.phase = transition.phase
        state.revision += 1
    }
}
