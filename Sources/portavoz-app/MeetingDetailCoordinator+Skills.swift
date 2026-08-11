import AppKit
import ApplicationKit
import PortavozCore
import UniformTypeIdentifiers

/// Q12/D316 — the skill proposal flow. The coordinator resolves everything a
/// proposal needs BEFORE the sheet exists (for export, the destination from
/// the native save panel), so the sheet can show the exact artifact and the
/// confirmed proposal never resolves anything behind the user's back.
extension MeetingDetailCoordinator {
    func openSkillOffer(
        _ offer: MeetingSkillOffer,
        detail: MeetingReviewReadModel
    ) {
        switch offer.kind {
        case .recapDraft, .emailRecapDraft:
            presentSkillSheet(offer, destination: nil)
        case .packageExport:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(detail.meeting.title).portavoz"
            if let type = UTType(filenameExtension: "portavoz") {
                panel.allowedContentTypes = [type]
            }
            panel.prompt = L10n.text("Export")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            presentSkillSheet(offer, destination: url.path)
        }
    }

    func dismissSkillOffer(_ offer: MeetingSkillOffer) {
        Task { await model.send(.dismissSkillOffer(offer)) }
    }

    /// The banner's load trigger; effects stay out of the view file.
    func loadSkillOffers() {
        Task { await model.send(.loadSkillOffers) }
    }

    /// Runs the confirmed skill and reports success so the sheet closes only
    /// when the durable outcome is actually success.
    func confirmSkill(
        _ target: MeetingDetailFlowState.SkillConfirmTarget
    ) async -> MeetingDetailFlowState.SkillConfirmationResult {
        let effect = await model.send(
            .performSkill(
                target.offer,
                proposalID: target.proposalID,
                proposedAt: target.proposedAt,
                preview: target.preview,
                destination: target.destination))
        guard case .skillPerformed = effect else {
            return .failed(
                model.state.lastActionError
                    ?? L10n.text("The skill could not run. Nothing left Portavoz."))
        }
        return .succeeded
    }

    private func presentSkillSheet(
        _ offer: MeetingSkillOffer,
        destination: String?
    ) {
        Task { @MainActor in
            guard let preview = await model.skillPreview(
                offer,
                destination: destination)
            else { return }
            flow.skillConfirmTarget = MeetingDetailFlowState.SkillConfirmTarget(
                proposalID: UUID(),
                proposedAt: Date(),
                offer: offer,
                preview: preview,
                destination: destination)
            flow.sheet = .confirmSkill
        }
    }
}
