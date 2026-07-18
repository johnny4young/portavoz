import ApplicationKit
import Foundation
import Observation
import OSLog
import PortavozCore

/// Per-detail owner of scoped loading, partial failure, and the current
/// storage-independent meeting review projection.
@MainActor
@Observable
final class MeetingDetailModel {
    private static let performanceSignposter = OSSignposter(
        subsystem: "app.portavoz.mac",
        category: "meeting-detail")

    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case missing
        case degraded(failures: Int)
        case failed
    }

    struct State {
        fileprivate(set) var phase: LoadPhase = .idle
        fileprivate(set) var readModel: MeetingReviewReadModel?
        fileprivate(set) var nameSuggestions: [MeetingNameSuggestion] = []
        fileprivate(set) var isSuggestingNames = false
        fileprivate(set) var voiceSuggestions: [MeetingVoiceSuggestion] = []
        fileprivate(set) var chapterTitles: [TimeInterval: String] = [:]
        fileprivate(set) var suggestedTitle: String?
        fileprivate(set) var suggestedRecipe: Recipe?
        fileprivate(set) var playback: PreparedMeetingPlayback?
        fileprivate(set) var isCompressingAudio = false
        fileprivate(set) var audioCompressionMessage: String?
        fileprivate(set) var revision = 0
        fileprivate(set) var lastActionError: String?
    }

    enum ContentAction {
        case renameMeeting(Meeting, title: String)
        case acceptNameSuggestion(Speaker, name: String)
        case acceptVoiceSuggestion(Speaker, name: String)
        case renameSpeaker(Speaker, name: String)
        case findCanonicalPeople(Speaker, source: PersonAliasSource)
        case linkCanonicalPerson(
            Speaker,
            source: PersonAliasSource,
            selection: CanonicalPersonSelection)
        case setActionItem(UUID, done: Bool)
        case setSummaryClaimFeedback(SummaryClaimID, SummaryClaimFeedback?)
        case removeCompanionCard(UUID)
    }

    enum ReviewAction {
        case deleteMeeting
        case retryProcessing
        case prepareDocument(MeetingDocumentFormat)
        case publishGist
        case loadNameSuggestions
        case loadVoiceSuggestions
        case loadMetadataSuggestions
        case loadPlayback
        case compressAudio
        case exportAudioClip(ClosedRange<TimeInterval>, to: URL)
        case checkVoiceMemoryOffer(name: String)
        case rememberVoice(SpeakerID)
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

        static func setSummaryClaimFeedback(
            _ claimID: SummaryClaimID,
            _ feedback: SummaryClaimFeedback?
        ) -> Self {
            .content(.setSummaryClaimFeedback(claimID, feedback))
        }

        static func removeCompanionCard(_ id: UUID) -> Self {
            .content(.removeCompanionCard(id))
        }

        static var deleteMeeting: Self { .review(.deleteMeeting) }
        static var retryProcessing: Self { .review(.retryProcessing) }

        static func prepareDocument(_ format: MeetingDocumentFormat) -> Self {
            .review(.prepareDocument(format))
        }

        static var publishGist: Self { .review(.publishGist) }
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
        case canonicalPeopleFound(Speaker, PersonAliasSource, [Person])
        case canonicalPersonLinked(ConfirmedPersonLink)
        case summaryClaimFeedbackSaved(SummaryClaimID)
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

    private(set) var state = State()
    let meetingID: MeetingID

    private let client: any MeetingDetailModelClient
    private let firstContentInterval: OSSignpostIntervalState
    private var didRenderFirstContent = false
    private var observationID = UUID()
    private var observedSections: Set<MeetingReviewSection> = []
    private var failedSections: Set<MeetingReviewSection> = []
    private var hasCoreSnapshot = false
    private var core: MeetingReviewCore?
    private var summary: MeetingReviewSummary?
    private var companionCards: [CompanionCard] = []
    private var privacyReceipt: PrivacyReceipt?
    private var processingJobs: [ProcessingJob] = []
    private var didLoadVoiceSuggestions = false
    private var didCompleteTitleSuggestion = false
    private var didCompleteRecipeSuggestion = false
    private var metadataRequestID = UUID()
    private var playbackDirectoryAttempt: String?

    init(meetingID: MeetingID, client: any MeetingDetailModelClient) {
        self.meetingID = meetingID
        self.client = client
        firstContentInterval = Self.performanceSignposter.beginInterval(
            "Meeting Detail First Content")
    }

    /// Ends the content-free navigation interval when SwiftUI mounts the
    /// first real Meeting Detail projection. Repeated appearances are ignored.
    func firstContentDidAppear() {
        guard !didRenderFirstContent else { return }
        didRenderFirstContent = true
        Self.performanceSignposter.endInterval(
            "Meeting Detail First Content",
            firstContentInterval)
    }

    /// Any explicit summary regeneration supersedes the optional recipe chip.
    func dismissSuggestedRecipe() {
        state.suggestedRecipe = nil
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
        let currentID = UUID()
        observationID = currentID
        state.phase = .loading
        observedSections = []
        failedSections = []

        for await update in client.observeMeetingReview(meetingID) {
            guard !Task.isCancelled, observationID == currentID else { return }
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
        case .renameMeeting(let meeting, let title):
            await renameMeeting(meeting, title: title)
            return nil
        case .acceptNameSuggestion(let speaker, let name):
            return await acceptNameSuggestion(speaker, name: name)
        case .acceptVoiceSuggestion(let speaker, let name):
            return await acceptVoiceSuggestion(speaker, name: name)
        case .renameSpeaker(let speaker, let name):
            return await renameSpeaker(speaker, name: name)
        case .findCanonicalPeople(let speaker, let source):
            return await findCanonicalPeople(speaker, source: source)
        case .linkCanonicalPerson(let speaker, let source, let selection):
            return await linkCanonicalPerson(
                speaker,
                source: source,
                selection: selection)
        case .setActionItem(let id, let done):
            await setActionItem(id, done: done)
            return nil
        case .setSummaryClaimFeedback(let claimID, let feedback):
            return await setSummaryClaimFeedback(feedback, for: claimID)
        case .removeCompanionCard(let id):
            await removeCompanionCard(id)
            return nil
        }
    }

    private func sendReviewAction(_ action: ReviewAction) async -> Effect? {
        switch action {
        case .deleteMeeting:
            await deleteMeeting()
            return .meetingDeleted(meetingID)
        case .retryProcessing:
            await retryProcessing()
            return nil
        case .prepareDocument(let format):
            return await prepareDocument(format)
        case .publishGist:
            return await publishGist()
        case .loadNameSuggestions:
            return await loadNameSuggestions()
        case .loadVoiceSuggestions:
            await loadVoiceSuggestions()
            return nil
        case .loadMetadataSuggestions:
            await loadMetadataSuggestions()
            return nil
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

    func prepareDocument(_ format: MeetingDocumentFormat) async -> Effect {
        do {
            return .documentPrepared(try await client.prepareMeetingDetailDocument(
                meetingID,
                format: format))
        } catch {
            return .operationFailed(error.localizedDescription)
        }
    }

    func publishGist() async -> Effect {
        do {
            return .gistPublished(try await client.publishMeetingDetailGist(meetingID))
        } catch {
            return .operationFailed(L10n.text(error.localizedDescription))
        }
    }

    func loadNameSuggestions() async -> Effect? {
        guard !state.isSuggestingNames else { return nil }
        state.isSuggestingNames = true
        defer { state.isSuggestingNames = false }
        do {
            state.nameSuggestions = try await client.meetingDetailNameSuggestions(meetingID)
            guard !state.nameSuggestions.isEmpty else {
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
    }

    func loadMetadataSuggestions() async {
        guard let detail = state.readModel else { return }
        let suggestMeetingTitle = !didCompleteTitleSuggestion
            && detail.meeting.title.first?.isNumber == true
            && detail.summary != nil
        let suggestRecipe = !didCompleteRecipeSuggestion
            && !detail.segments.isEmpty
            && detail.summary?.draft.recipeID == Recipe.general.id
        let chapterStarts = Set(
            ChapterExtractor.chapters(from: detail.segments).map(\.startTime))
        let titledStarts = Set(state.chapterTitles.keys)
        guard suggestMeetingTitle
                || suggestRecipe
                || !chapterStarts.isSubset(of: titledStarts)
        else { return }

        let request = SuggestMeetingReviewMetadataRequest(
            review: detail,
            titledChapterStarts: titledStarts,
            suggestMeetingTitle: suggestMeetingTitle,
            suggestRecipe: suggestRecipe)
        let currentID = UUID()
        metadataRequestID = currentID

        do {
            let suggestions = try await client.meetingDetailMetadataSuggestions(request)
            guard !Task.isCancelled, metadataRequestID == currentID else { return }
            if suggestMeetingTitle {
                didCompleteTitleSuggestion = true
                state.suggestedTitle = suggestions.meetingTitle
            }
            if suggestRecipe {
                didCompleteRecipeSuggestion = true
                state.suggestedRecipe = suggestions.recipe
            }
            state.chapterTitles.merge(suggestions.chapterTitles) { _, new in new }
        } catch is CancellationError {
            // A newer read revision retries every still-eligible suggestion.
        } catch {
            guard metadataRequestID == currentID else { return }
            // Optional intelligence degrades silently, as before. Mark only
            // the attempted one-shot suggestions complete to avoid a loop;
            // missing chapter labels may retry after a future read revision.
            if suggestMeetingTitle { didCompleteTitleSuggestion = true }
            if suggestRecipe { didCompleteRecipeSuggestion = true }
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
                    destination: destination))
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
                error.localizedDescription))
        }
    }
}

private extension MeetingDetailModel {
    func publish(_ update: MeetingReviewUpdate) {
        // Reject optional intelligence generated from an older projection.
        metadataRequestID = UUID()
        switch update {
        case .core(let value):
            core = value
            hasCoreSnapshot = true
            markObserved(.core)
        case .summary(let value):
            summary = value
            markObserved(.summary)
        case .companionCards(let value):
            companionCards = value
            markObserved(.companion)
        case .privacyReceipt(let value):
            privacyReceipt = value
            markObserved(.privacy)
        case .processingJobs(let value):
            processingJobs = value
            markObserved(.processing)
        case .failed(let section):
            failedSections.insert(section)
            observedSections.remove(section)
            if section == .core, !hasCoreSnapshot {
                hasCoreSnapshot = true
                core = nil
            }
        }
        refreshReadModel()
        refreshPhase()
        state.revision += 1
    }

    func markObserved(_ section: MeetingReviewSection) {
        observedSections.insert(section)
        failedSections.remove(section)
    }

    func refreshReadModel() {
        guard let core else {
            invalidatePlayback()
            state.readModel = nil
            return
        }
        let previousAudioDirectory = state.readModel?.meeting.audioDirectory
        if previousAudioDirectory != core.meeting.audioDirectory,
            previousAudioDirectory != nil {
            invalidatePlayback()
        }
        state.readModel = MeetingReviewReadModel(
            core: core,
            summary: summary,
            companionCards: companionCards,
            privacyReceipt: privacyReceipt,
            processingJobs: processingJobs)
    }

    func refreshPhase() {
        let accountedSections = observedSections.union(failedSections)
        guard accountedSections.count == MeetingReviewSection.allCases.count else {
            state.phase = .loading
            return
        }
        if core == nil, observedSections.contains(.core) {
            state.phase = .missing
            return
        }
        guard failedSections.count < MeetingReviewSection.allCases.count,
            !(failedSections.contains(.core) && core == nil)
        else {
            state.phase = .failed
            return
        }
        if !failedSections.isEmpty {
            state.phase = .degraded(failures: failedSections.count)
            return
        }
        state.phase = .loaded
    }
}
