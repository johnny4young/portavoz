import ApplicationKit
import Foundation
import Observation
import OSLog
import PortavozCore

/// Narrow read-side contract for one Meeting Detail feature instance.
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
    func canRememberMeetingDetailVoice(named name: String) async -> Bool
    func rememberMeetingDetailVoice(
        meetingID: MeetingID,
        speakerID: SpeakerID
    ) async throws -> ManageMeetingVoiceMemoryResult
    func requestMeetingDetailSearchReindex()
}

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
        _ = try? await client.renameMeetingDetailMeeting(meeting)
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
            state.readModel = nil
            return
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
