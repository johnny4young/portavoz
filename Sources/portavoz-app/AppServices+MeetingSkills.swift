import AppKit
import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

/// Q12/D316 — the app-side composition of the no-egress meeting skills.
///
/// Everything here is an adapter: the offer policy, the proposal factory, and
/// the execution machinery live in ApplicationKit; the pasteboard, the file
/// system, and the store are what the app contributes.
extension AppServices {
    func meetingDetailSkillOffers(
        meetingID: MeetingID,
        hasSummary: Bool
    ) async throws -> [MeetingSkillOffer] {
        try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(
                meetingID: meetingID,
                hasSummary: hasSummary))
    }

    func meetingDetailSkillReceipts(
        meetingID: MeetingID
    ) async throws -> [MeetingSkillReceipt] {
        try await LoadMeetingSkillReceipts(store: store).execute(meetingID)
    }

    func dismissMeetingDetailSkillOffer(
        _ offer: MeetingSkillOffer
    ) async throws {
        try await store.dismissSkillOffer(
            offerKey: offer.offerKey,
            skillID: offer.skillID,
            at: Date())
    }

    /// The preview is the exact artifact: composed read-only, before any
    /// durable claim exists.
    func meetingDetailSkillPreview(
        _ offer: MeetingSkillOffer,
        destination: String?
    ) async throws -> MeetingSkillPreview {
        switch offer.kind {
        case .recapDraft:
            guard let source = try await AppRecapMaterialReader(store: store)
                .recapMaterial(for: offer.meetingID)
            else { throw RecapDraftError.noSummaryToRecap }
            return AppConfirmedRecapMaterial(source: source).preview
        case .packageExport:
            guard let destination else {
                throw MeetingPackageExportError.missingDestination
            }
            let detail = try await store.detail(offer.meetingID)
            return .packageExport(
                meetingTitle: detail?.meeting.title ?? "",
                destination: destination)
        }
    }

    /// Runs one confirmed offer through the durable execution machinery.
    /// Returns nil on success, or the localized failure the sheet shows.
    func performMeetingDetailSkill(
        _ offer: MeetingSkillOffer,
        proposalID: UUID,
        preview: MeetingSkillPreview,
        destination: String?
    ) async throws -> String? {
        guard let plan = try await meetingSkillExecutionPlan(
            offer,
            requestedProposalID: proposalID,
            preview: preview,
            destination: destination)
        else { return staleSkillProposalFailure }
        let outcome = try await ExecuteSkill(
            claims: store,
            policy: store,
            effects: plan.effects
        ).execute(ExecuteSkillRequest(
            proposal: plan.proposal,
            isConfirmedByUser: true,
            egressIsPermitted: false,
            idempotencyKey: plan.idempotencyKey))
        return meetingSkillFailure(for: outcome)
    }

    private func meetingSkillExecutionPlan(
        _ offer: MeetingSkillOffer,
        requestedProposalID: UUID,
        preview: MeetingSkillPreview,
        destination: String?
    ) async throws -> AppMeetingSkillExecutionPlan? {
        switch offer.kind {
        case .recapDraft:
            try await recapSkillExecutionPlan(
                offer,
                requestedProposalID: requestedProposalID,
                preview: preview)
        case .packageExport:
            try await packageSkillExecutionPlan(
                offer,
                requestedProposalID: requestedProposalID,
                preview: preview,
                destination: destination)
        }
    }

    private func recapSkillExecutionPlan(
        _ offer: MeetingSkillOffer,
        requestedProposalID: UUID,
        preview: MeetingSkillPreview
    ) async throws -> AppMeetingSkillExecutionPlan? {
        guard let source = try await AppRecapMaterialReader(store: store)
            .recapMaterial(for: offer.meetingID)
        else { throw RecapDraftError.noSummaryToRecap }
        guard let confirmed = AppConfirmedRecapMaterial(
            source: source,
            approvedPreview: preview
        ) else { return nil }
        // Revalidate before resolving or writing any durable claim.
        let key = RecapDraftSkill.idempotencyKey(for: offer.meetingID)
        let durableProposalID = try await skillProposalID(
            requested: requestedProposalID,
            idempotencyKey: key)
        let proposal = MeetingSkillProposalFactory.recapProposal(
            proposalID: durableProposalID,
            meetingID: offer.meetingID,
            at: Date()).proposal
        return AppMeetingSkillExecutionPlan(
            proposal: proposal,
            idempotencyKey: key,
            effects: [
                RecapDraftSkill.id: RecapDraftEffect(
                    material: confirmed,
                    delivery: recapSkillDelivery)
            ])
    }

    private func packageSkillExecutionPlan(
        _ offer: MeetingSkillOffer,
        requestedProposalID: UUID,
        preview: MeetingSkillPreview,
        destination: String?
    ) async throws -> AppMeetingSkillExecutionPlan? {
        guard let destination else {
            throw MeetingPackageExportError.missingDestination
        }
        guard try await meetingDetailSkillPreview(
            offer,
            destination: destination
        ) == preview else { return nil }
        let key = MeetingPackageExportSkill.idempotencyKey(
            for: offer.meetingID,
            destination: destination)
        let durableProposalID = try await skillProposalID(
            requested: requestedProposalID,
            idempotencyKey: key)
        let proposal = MeetingSkillProposalFactory.packageExportProposal(
            proposalID: durableProposalID,
            meetingID: offer.meetingID,
            destination: destination,
            at: Date()).proposal
        return AppMeetingSkillExecutionPlan(
            proposal: proposal,
            idempotencyKey: key,
            effects: [
                MeetingPackageExportSkill.id: MeetingPackageExportEffect(
                    export: exportMeetingBundleUseCaseForSkills,
                    destination: AppMeetingPackageWriter())
            ])
    }

    /// A failed/confirmed/interrupted execution keeps ownership of its unique
    /// effect key even if SwiftUI reconstructs the sheet. Reattach to that
    /// durable proposal; never ask storage to transfer the claim to a new UUID.
    private func skillProposalID(
        requested: UUID,
        idempotencyKey: String
    ) async throws -> UUID {
        try await store.skillExecution(idempotencyKey: idempotencyKey)?
            .proposalID ?? requested
    }

    private func meetingSkillFailure(
        for outcome: SkillExecutionOutcome
    ) -> String? {
        switch outcome {
        case .performed, .alreadySettled(.succeeded):
            return nil
        case .refused(.allSkillsPaused):
            return L10n.text("Skills are paused in Settings.")
        case .refused(.skillDisabled):
            return L10n.text("This skill is disabled in Settings.")
        case .alreadySettled, .refused, .rejected:
            return staleSkillProposalFailure
        case .failed:
            return L10n.text("The skill ran and failed. Nothing left Portavoz.")
        }
    }

    private var exportMeetingBundleUseCaseForSkills: ExportMeetingBundle {
        ExportMeetingBundle(
            store: store,
            // The skills tier is text-only (D295): the files port returns no
            // audio, and the effect itself also requests includeAudio: false.
            files: AppSkillExportBundleFiles(),
            documents: AppSkillExportBundleDocuments())
    }

    private var staleSkillProposalFailure: String {
        L10n.text(
            "This skill run could not start. Its proposal may be stale.")
    }
}

private struct AppMeetingSkillExecutionPlan {
    let proposal: SkillProposal
    let idempotencyKey: String
    let effects: [String: any SkillEffectPerforming]
}

extension AppServices {
    static func makeRecapSkillDelivery(
        arguments: [String],
        usesTemporaryStore: Bool
    ) -> any RecapDraftDelivering {
        guard usesTemporaryStore,
              arguments.contains("-simulate-skill-effect-failure-once")
        else { return AppRecapPasteboardDelivery() }
        return AppRecapPasteboardDelivery(
            pasteboard: AppFailingOnceRecapPasteboard())
    }
}

/// Reads the recap material from durable truth only.
struct AppRecapMaterialReader: RecapMaterialReading {
    let store: MeetingStore

    func recapMaterial(
        for meetingID: MeetingID
    ) async throws -> (meeting: Meeting, speakers: [Speaker], summary: SummaryDraft)? {
        guard let detail = try await store.detail(meetingID),
              let summary = try await store.mostRecentSummary(meetingID)
        else { return nil }
        return (detail.meeting, detail.speakers, summary.draft)
    }
}

/// The durable recap material captured at confirmation. Reusing this exact
/// snapshot inside the effect prevents a second store read from changing the
/// artifact after the user approved it.
struct AppConfirmedRecapMaterial: RecapMaterialReading {
    let meeting: Meeting
    let speakers: [Speaker]
    let summary: SummaryDraft
    let preview: MeetingSkillPreview

    init(
        source: (meeting: Meeting, speakers: [Speaker], summary: SummaryDraft)
    ) {
        meeting = source.meeting
        speakers = source.speakers
        summary = source.summary
        let recap = RecapComposer.compose(
            meeting: source.meeting,
            speakers: source.speakers,
            summary: source.summary)
        preview = .recap(
            subject: recap.subject,
            body: MeetingExporter.render(recap.markdown, format: .plainText))
    }

    init?(
        source: (meeting: Meeting, speakers: [Speaker], summary: SummaryDraft),
        approvedPreview: MeetingSkillPreview
    ) {
        self.init(source: source)
        guard preview == approvedPreview else { return nil }
    }

    func recapMaterial(
        for meetingID: MeetingID
    ) async throws -> (meeting: Meeting, speakers: [Speaker], summary: SummaryDraft)? {
        guard meeting.id == meetingID else { return nil }
        return (meeting, speakers, summary)
    }
}

protocol RecapPasteboardWriting: Sendable {
    func replaceString(_ string: String) async -> Bool
}

struct SystemRecapPasteboard: RecapPasteboardWriting {
    func replaceString(_ string: String) async -> Bool {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(string, forType: .string)
        }
    }
}

/// Deterministic disposable-app fixture: the first handoff is refused and the
/// retry uses the real pasteboard. Production construction cannot select it.
actor AppFailingOnceRecapPasteboard: RecapPasteboardWriting {
    private var hasRejected = false
    private let system = SystemRecapPasteboard()

    func replaceString(_ string: String) async -> Bool {
        guard hasRejected else {
            hasRejected = true
            return false
        }
        return await system.replaceString(string)
    }
}

enum AppRecapPasteboardError: Error, CategorizedFailure {
    case writeRejected

    var category: FailureCategory { .recoverable }
}

/// The local draft destination for a confirmed recap: the pasteboard, exactly
/// what the manual sheet's Copy does — the user still sends it themselves.
struct AppRecapPasteboardDelivery: RecapDraftDelivering {
    let pasteboard: any RecapPasteboardWriting

    init(
        pasteboard: any RecapPasteboardWriting = SystemRecapPasteboard()
    ) {
        self.pasteboard = pasteboard
    }

    func deliver(_ recap: MeetingRecap) async throws {
        let text = "\(recap.subject)\n\n"
            + MeetingExporter.render(recap.markdown, format: .plainText)
        guard await pasteboard.replaceString(text) else {
            throw AppRecapPasteboardError.writeRejected
        }
    }
}

/// Writes the package to the destination the user already chose in the save
/// panel. Atomic so a failed write never leaves a half package at the path
/// the receipt claims.
struct AppMeetingPackageWriter: MeetingPackageWriting {
    func write(
        _ package: Data,
        for meetingID: MeetingID,
        to destination: String
    ) async throws {
        try package.write(
            to: URL(fileURLWithPath: destination),
            options: .atomic)
    }
}

/// The skills tier is text-only (D295): no audio ever enters the package, so
/// the files port legitimately returns nothing.
private struct AppSkillExportBundleFiles: ExportMeetingBundleFiles {
    func readBundleAudio(
        from relativeDirectory: String
    ) async -> [ExportMeetingBundleAttachment] {
        []
    }
}

private struct AppSkillExportBundleDocuments: ExportMeetingBundleDocuments {
    func encodeMeetingBundle(
        _ document: ExportMeetingBundleDocument
    ) async throws -> Data {
        try MeetingBundle(
            meeting: document.meeting,
            speakers: document.speakers,
            segments: document.segments,
            summary: document.summary,
            contextItems: document.contextItems,
            companionCards: document.companionCards,
            audioFiles: nil
        ).encoded()
    }
}
