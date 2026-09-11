import ApplicationKit
import Foundation
import PortavozCore

enum MeetingDetailLoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case missing
    case degraded(failures: Int)
    case failed
}

/// Pure owner of independently observed Meeting Detail review sections.
///
/// The accumulator retains each last healthy section across observation
/// restarts, while resetting only delivery accounting. It returns explicit
/// invalidation signals so the route model remains the sole owner of UI state
/// and playback lifetimes.
struct MeetingDetailReviewAccumulator {
    struct Transition {
        let phase: MeetingDetailLoadPhase
        let readModel: MeetingReviewReadModel?
        let correctionRevisionChanged: Bool
        let shouldInvalidatePlayback: Bool
    }

    private var observationID = UUID()
    private var observedSections: Set<MeetingReviewSection> = []
    private var failedSections: Set<MeetingReviewSection> = []
    private var hasCoreSnapshot = false
    private var core: MeetingReviewCore?
    private var summary: MeetingReviewSummary?
    private var companionCards: [CompanionCard] = []
    private var companionCorrectionSources:
        [UUID: TranscriptCorrectionArtifactSource] = [:]
    private var privacyReceipt: PrivacyReceipt?
    private var processingJobs: [ProcessingJob] = []
    private var notes = MeetingReviewNotes()
    private var commitmentReviewStates: [CommitmentReviewState] = []

    mutating func beginObservation() -> UUID {
        let id = UUID()
        observationID = id
        observedSections = []
        failedSections = []
        return id
    }

    func accepts(observationID: UUID) -> Bool {
        self.observationID == observationID
    }

    mutating func apply(_ update: MeetingReviewUpdate) -> Transition {
        let previousAudioDirectory = readModel?.meeting.audioDirectory
        let correctionRevisionChanged = applySection(update)
        let currentReadModel = readModel
        let currentAudioDirectory = currentReadModel?.meeting.audioDirectory
        return Transition(
            phase: phase,
            readModel: currentReadModel,
            correctionRevisionChanged: correctionRevisionChanged,
            shouldInvalidatePlayback: currentReadModel == nil
                || (previousAudioDirectory != nil
                    && previousAudioDirectory != currentAudioDirectory))
    }
}

private extension MeetingDetailReviewAccumulator {
    var readModel: MeetingReviewReadModel? {
        guard let core else { return nil }
        return MeetingReviewReadModel(
            core: core,
            summary: summary,
            companionCards: companionCards,
            companionCorrectionSources: companionCorrectionSources,
            privacyReceipt: privacyReceipt,
            processingJobs: processingJobs,
            notes: notes,
            commitmentReviewStates: commitmentReviewStates)
    }

    var phase: MeetingDetailLoadPhase {
        let accountedSections = observedSections.union(failedSections)
        guard accountedSections.count == MeetingReviewSection.allCases.count else {
            return .loading
        }
        if core == nil, observedSections.contains(.core) {
            return .missing
        }
        guard failedSections.count < MeetingReviewSection.allCases.count,
            !(failedSections.contains(.core) && core == nil)
        else {
            return .failed
        }
        guard !failedSections.isEmpty else { return .loaded }
        return .degraded(failures: failedSections.count)
    }

    mutating func applySection(_ update: MeetingReviewUpdate) -> Bool {
        switch update {
        case .core(let value):
            let revisionChanged = core?.correctionRevision != value?.correctionRevision
            core = value
            hasCoreSnapshot = true
            markObserved(.core)
            return revisionChanged
        case .summary(let value):
            summary = value
            markObserved(.summary)
        case .companionCards(let cards, let correctionSources):
            companionCards = cards
            companionCorrectionSources = correctionSources
            markObserved(.companion)
        case .privacyReceipt(let value):
            privacyReceipt = value
            markObserved(.privacy)
        case .processingJobs(let value):
            processingJobs = value
            markObserved(.processing)
        case .notes(let value):
            notes = value
            markObserved(.notes)
        case .commitmentReviewStates(let value):
            commitmentReviewStates = value
            markObserved(.commitments)
        case .failed(let section):
            failedSections.insert(section)
            observedSections.remove(section)
            if section == .core, !hasCoreSnapshot {
                hasCoreSnapshot = true
                core = nil
            }
        }
        return false
    }

    mutating func markObserved(_ section: MeetingReviewSection) {
        observedSections.insert(section)
        failedSections.remove(section)
    }
}
