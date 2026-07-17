import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// Narrow read-side contract for one Meeting Detail feature instance.
@MainActor
protocol MeetingDetailModelClient: AnyObject {
    func observeMeetingReview(
        _ meetingID: MeetingID
    ) -> AsyncStream<MeetingReviewUpdate>

    func renameMeetingDetailMeeting(_ meeting: Meeting) async throws
    func renameMeetingDetailSpeaker(_ speaker: Speaker) async throws
    func setMeetingDetailActionItem(_ id: UUID, done: Bool) async throws
    func deleteMeetingDetailCompanionCard(_ id: UUID) async throws
    func deleteMeetingDetail(_ id: MeetingID) async throws
    func retryMeetingDetailProcessing(_ meetingID: MeetingID) async throws
    func requestMeetingDetailSearchReindex()
}

/// Per-detail owner of scoped loading, partial failure, and the current
/// storage-independent meeting review projection.
@MainActor
@Observable
final class MeetingDetailModel {
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
        fileprivate(set) var revision = 0
        fileprivate(set) var lastActionError: String?
    }

    enum Action {
        case renameMeeting(Meeting, title: String)
        case acceptNameSuggestion(Speaker, name: String)
        case acceptVoiceSuggestion(Speaker, name: String)
        case renameSpeaker(Speaker, name: String)
        case setActionItem(UUID, done: Bool)
        case removeCompanionCard(UUID)
        case deleteMeeting
        case retryProcessing
        case searchableContentChanged
    }

    enum Effect {
        case nameSuggestionAccepted(Speaker)
        case voiceSuggestionAccepted(Speaker)
        case speakerRenamed(Speaker)
        case meetingDeleted(MeetingID)
    }

    private(set) var state = State()
    let meetingID: MeetingID

    private let client: any MeetingDetailModelClient
    private var observationID = UUID()
    private var observedSections: Set<MeetingReviewSection> = []
    private var failedSections: Set<MeetingReviewSection> = []
    private var hasCoreSnapshot = false
    private var core: MeetingReviewCore?
    private var summary: MeetingReviewSummary?
    private var companionCards: [CompanionCard] = []
    private var privacyReceipt: PrivacyReceipt?
    private var processingJobs: [ProcessingJob] = []

    init(meetingID: MeetingID, client: any MeetingDetailModelClient) {
        self.meetingID = meetingID
        self.client = client
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
        case .renameMeeting(let meeting, let title):
            await renameMeeting(meeting, title: title)
            return nil
        case .acceptNameSuggestion(let speaker, let name):
            return await acceptNameSuggestion(speaker, name: name)
        case .acceptVoiceSuggestion(let speaker, let name):
            return await acceptVoiceSuggestion(speaker, name: name)
        case .renameSpeaker(let speaker, let name):
            return await renameSpeaker(speaker, name: name)
        case .setActionItem(let id, let done):
            await setActionItem(id, done: done)
            return nil
        case .removeCompanionCard(let id):
            await removeCompanionCard(id)
            return nil
        case .deleteMeeting:
            await deleteMeeting()
            return .meetingDeleted(meetingID)
        case .retryProcessing:
            await retryProcessing()
            return nil
        case .searchableContentChanged:
            client.requestMeetingDetailSearchReindex()
            return nil
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
        _ = try? await client.renameMeetingDetailSpeaker(speaker)
        client.requestMeetingDetailSearchReindex()
        return .nameSuggestionAccepted(speaker)
    }

    func acceptVoiceSuggestion(_ original: Speaker, name: String) async -> Effect {
        var speaker = original
        speaker.displayName = name
        _ = try? await client.renameMeetingDetailSpeaker(speaker)
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

    func setActionItem(_ id: UUID, done: Bool) async {
        _ = try? await client.setMeetingDetailActionItem(id, done: done)
        client.requestMeetingDetailSearchReindex()
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
