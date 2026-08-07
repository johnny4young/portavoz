import Foundation
import Observation
import PortavozCore
import UniformTypeIdentifiers

struct PersonRememberOffer {
    let speaker: Speaker
    let source: PersonAliasSource
}

struct MeetingDetailExportRoute {
    let document: ExportDocument
    let contentType: UTType
    let defaultFilename: String
}

/// Route-lifetime presentation state for Meeting Detail secondary flows.
///
/// The scene owns one instance. Mutually exclusive sheets, dialogs, and alerts
/// are modeled as routes instead of independent booleans, while long-running
/// operation progress remains explicit and can coexist with presentation.
@MainActor
@Observable
final class MeetingDetailFlowState {
    enum SheetRoute: String, Identifiable {
        case renameMeeting
        case recap
        case newStructure
        case confirmDecision

        var id: String { rawValue }
    }

    /// The generated decision the confirm sheet is acting on. Route payload
    /// kept beside the route, matching the rename-title pattern.
    struct DecisionConfirmTarget: Equatable {
        let observationID: SummaryDecisionID
        let statement: String
        let meetingID: MeetingID
        let evidenceSegmentID: UUID
        let sourceTranscriptRevision: Int
    }

    enum DialogRoute: Identifiable {
        case publishGist
        case choosePerson(PersonRememberOffer, candidates: [Person])

        var id: String {
            switch self {
            case .publishGist: "publish-gist"
            case .choosePerson: "choose-person"
            }
        }
    }

    enum AlertRoute: Identifiable {
        case gistPublished(URL)
        case summaryNotice(String)
        case summarySetup(SummarySetupIssue)
        case failure(String)
        case renameSpeaker(Speaker)

        var id: String {
            switch self {
            case .gistPublished: "gist-published"
            case .summaryNotice: "summary-notice"
            case .summarySetup: "summary-setup"
            case .failure: "failure"
            case .renameSpeaker: "rename-speaker"
            }
        }
    }

    var sheet: SheetRoute?
    var dialog: DialogRoute?
    var alert: AlertRoute?
    var export: MeetingDetailExportRoute?
    var includeCorrectionProvenance = false

    var renameMeetingTitle = ""
    var decisionConfirmTarget: DecisionConfirmTarget?
    var renameSpeakerName = ""
    var isRegenerating = false
    var isEnhancingNotes = false
    var notesNotice: String?
    var applyingStatus: String?
    var operationError: String?

    var personOffer: PersonRememberOffer?
    var rememberedVoiceOffer: Speaker?
    var isFindingPerson = false
    var isRememberingVoice = false

    var mirrorAverageShare: Double?
    var mirrorAverageLoadedFor: MeetingID?

    func presentRenameMeeting(title: String) {
        renameMeetingTitle = title
        sheet = .renameMeeting
    }

    func presentRenameSpeaker(_ speaker: Speaker) {
        renameSpeakerName = speaker.displayName ?? ""
        alert = .renameSpeaker(speaker)
    }

    func presentPersonChoice(_ offer: PersonRememberOffer, candidates: [Person]) {
        guard !candidates.isEmpty else { return }
        dialog = .choosePerson(offer, candidates: candidates)
    }

    var renamingSpeaker: Speaker? {
        guard case .renameSpeaker(let speaker) = alert else { return nil }
        return speaker
    }

    var personChoice: (offer: PersonRememberOffer, candidates: [Person])? {
        guard case .choosePerson(let offer, let candidates) = dialog else { return nil }
        return (offer, candidates)
    }
}
