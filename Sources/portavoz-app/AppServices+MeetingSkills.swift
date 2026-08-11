import AppKit
import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

/// Q12/D316/D327 — app-side composition of meeting-scoped Skills.
///
/// Everything here is an adapter: ApplicationKit owns policy and execution;
/// the app contributes pasteboard, file-system, email-composer, and store
/// boundaries.
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
        case .emailRecapDraft:
            guard let source = try await AppRecapMaterialReader(store: store)
                .recapMaterial(for: offer.meetingID)
            else { throw EmailRecapDraftError.noSummaryToRecap }
            return AppConfirmedEmailRecapMaterial(source: source).preview
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
        proposedAt: Date,
        preview: MeetingSkillPreview,
        destination: String?
    ) async throws -> String? {
        guard let plan = try await meetingSkillExecutionPlan(
            offer,
            requestedProposalID: proposalID,
            proposedAt: proposedAt,
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
            egressIsPermitted: plan.egressIsPermitted,
            idempotencyKey: plan.idempotencyKey))
        return meetingSkillFailure(for: outcome, offer: offer)
    }

    private func meetingSkillExecutionPlan(
        _ offer: MeetingSkillOffer,
        requestedProposalID: UUID,
        proposedAt: Date,
        preview: MeetingSkillPreview,
        destination: String?
    ) async throws -> AppMeetingSkillExecutionPlan? {
        switch offer.kind {
        case .recapDraft:
            try await recapSkillExecutionPlan(
                offer,
                requestedProposalID: requestedProposalID,
                proposedAt: proposedAt,
                preview: preview)
        case .emailRecapDraft:
            try await emailRecapSkillExecutionPlan(
                offer,
                requestedProposalID: requestedProposalID,
                proposedAt: proposedAt,
                preview: preview)
        case .packageExport:
            try await packageSkillExecutionPlan(
                offer,
                requestedProposalID: requestedProposalID,
                proposedAt: proposedAt,
                preview: preview,
                destination: destination)
        }
    }

    private func recapSkillExecutionPlan(
        _ offer: MeetingSkillOffer,
        requestedProposalID: UUID,
        proposedAt: Date,
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
            at: proposedAt).proposal
        return AppMeetingSkillExecutionPlan(
            proposal: proposal,
            idempotencyKey: key,
            egressIsPermitted: false,
            effects: [
                RecapDraftSkill.id: RecapDraftEffect(
                    material: confirmed,
                    delivery: recapSkillDelivery)
            ])
    }

    private func emailRecapSkillExecutionPlan(
        _ offer: MeetingSkillOffer,
        requestedProposalID: UUID,
        proposedAt: Date,
        preview: MeetingSkillPreview
    ) async throws -> AppMeetingSkillExecutionPlan? {
        guard let source = try await AppRecapMaterialReader(store: store)
            .recapMaterial(for: offer.meetingID)
        else { throw EmailRecapDraftError.noSummaryToRecap }
        guard let confirmed = AppConfirmedEmailRecapMaterial(
            source: source,
            approvedPreview: preview
        ) else { return nil }
        let key = EmailRecapDraftSkill.idempotencyKey(for: offer.meetingID)
        let durableProposalID = try await skillProposalID(
            requested: requestedProposalID,
            idempotencyKey: key)
        let proposal = MeetingSkillProposalFactory.emailRecapDraftProposal(
            proposalID: durableProposalID,
            meetingID: offer.meetingID,
            at: proposedAt).proposal
        return AppMeetingSkillExecutionPlan(
            proposal: proposal,
            idempotencyKey: key,
            // The submit action is the exact per-proposal egress permission:
            // the sheet shows the full text and the email-app boundary first.
            egressIsPermitted: true,
            effects: [
                EmailRecapDraftSkill.id: EmailRecapDraftEffect(
                    material: confirmed,
                    delivery: emailRecapDraftDelivery)
            ])
    }

    private func packageSkillExecutionPlan(
        _ offer: MeetingSkillOffer,
        requestedProposalID: UUID,
        proposedAt: Date,
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
            at: proposedAt).proposal
        return AppMeetingSkillExecutionPlan(
            proposal: proposal,
            idempotencyKey: key,
            egressIsPermitted: false,
            effects: [
                MeetingPackageExportSkill.id: MeetingPackageExportEffect(
                    export: exportMeetingBundleUseCaseForSkills,
                    destination: AppMeetingPackageWriter())
            ])
    }

    /// A failed/confirmed/interrupted execution keeps ownership of its unique
    /// effect key even if SwiftUI reconstructs the sheet. Reattach to that
    /// durable proposal; never ask storage to transfer the claim to a new UUID.
    func skillProposalID(
        requested: UUID,
        idempotencyKey: String
    ) async throws -> UUID {
        try await store.skillExecution(idempotencyKey: idempotencyKey)?
            .proposalID ?? requested
    }

    private func meetingSkillFailure(
        for outcome: SkillExecutionOutcome,
        offer: MeetingSkillOffer
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
        case .failed where offer.kind == .emailRecapDraft:
            return L10n.text(
                "The email draft could not be opened. Portavoz did not send it.")
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
    let egressIsPermitted: Bool
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

    static func makeEmailRecapDraftDelivery(
        usesTemporaryStore: Bool
    ) -> any EmailRecapDraftDelivering {
        let opener: any AppEmailDraftOpening = usesTemporaryStore
            ? AppDisposableEmailDraftOpener()
            : AppSystemEmailDraftOpener()
        return AppEmailRecapDraftDelivery(opener: opener)
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
    let recap: MeetingRecap
    let preview: MeetingSkillPreview

    init(
        source: (meeting: Meeting, speakers: [Speaker], summary: SummaryDraft)
    ) {
        meeting = source.meeting
        speakers = source.speakers
        summary = source.summary
        recap = RecapComposer.compose(
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

/// The same captured recap material, expressed as an email-specific preview so
/// a clipboard approval can never be reused as permission for an external-app
/// handoff (or vice versa).
struct AppConfirmedEmailRecapMaterial: RecapMaterialReading {
    let material: AppConfirmedRecapMaterial
    let preview: MeetingSkillPreview

    init(
        source: (meeting: Meeting, speakers: [Speaker], summary: SummaryDraft)
    ) {
        let material = AppConfirmedRecapMaterial(source: source)
        self.material = material
        preview = .emailDraft(
            subject: material.recap.subject,
            body: MeetingExporter.render(
                material.recap.markdown,
                format: .plainText))
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
        try await material.recapMaterial(for: meetingID)
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

protocol AppEmailDraftOpening: Sendable {
    func openDraft(subject: String, body: String) async -> Bool
}

/// Creates the AppKit service only inside MainActor work. The framework object
/// is non-Sendable and must never become process-owned state under Swift 6.
struct AppSystemEmailDraftOpener: AppEmailDraftOpening {
    func openDraft(subject: String, body: String) async -> Bool {
        await MainActor.run {
            let items: [Any] = [body]
            guard let service = NSSharingService(named: .composeEmail),
                  service.canPerform(withItems: items)
            else { return false }
            // Audience selection belongs to the user in their email app.
            service.recipients = []
            service.subject = subject
            service.perform(withItems: items)
            return true
        }
    }
}

/// Disposable UI automation crosses the real application/effect path but not
/// the host email client. Production composition cannot select this adapter.
private struct AppDisposableEmailDraftOpener: AppEmailDraftOpening {
    func openDraft(subject: String, body: String) async -> Bool {
        !subject.isEmpty && !body.isEmpty
    }
}

enum AppEmailRecapDraftError: Error, CategorizedFailure {
    case handoffUnavailable

    var category: FailureCategory { .recoverable }
}

struct AppEmailRecapDraftDelivery: EmailRecapDraftDelivering {
    let opener: any AppEmailDraftOpening

    func deliver(_ recap: MeetingRecap) async throws {
        let body = MeetingExporter.render(recap.markdown, format: .plainText)
        guard await opener.openDraft(subject: recap.subject, body: body)
        else { throw AppEmailRecapDraftError.handoffUnavailable }
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
