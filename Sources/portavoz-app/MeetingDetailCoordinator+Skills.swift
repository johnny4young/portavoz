import AppKit
import ApplicationKit
import PortavozCore
import UniformTypeIdentifiers

/// Q12/D316 — the skill proposal flow. The coordinator resolves everything a
/// proposal needs BEFORE the sheet exists (for export, the destination from
/// the native save panel), so the sheet can show the exact artifact and the
/// confirmed proposal never resolves anything behind the user's back.
extension MeetingDetailCoordinator {
    func openGitHubIssueSkill(_ item: ActionItem) {
        flow.githubIssueTarget = MeetingDetailFlowState.GitHubIssueTarget(
            meetingID: meetingID,
            actionItemID: item.id,
            actionItemText: item.text)
        flow.sheet = .githubIssueSkill
    }

    func prepareGitHubIssueSkill(
        _ target: MeetingDetailFlowState.GitHubIssueTarget,
        repository: String
    ) async -> MeetingDetailFlowState.GitHubIssueDraftResult {
        let effect = await model.send(.prepareGitHubIssue(
            PrepareGitHubIssueDraftRequest(
                meetingID: target.meetingID,
                actionItemID: target.actionItemID,
                repository: repository)))
        guard case .gitHubIssuePrepared(let draft) = effect else {
            return .failed(model.state.lastActionError ?? L10n.text(
                "The issue draft could not be prepared."))
        }
        return .prepared(draft)
    }

    func confirmGitHubIssueSkill(
        _ draft: GitHubIssueDraft,
        proposalID: UUID,
        proposedAt: Date
    ) async -> MeetingDetailFlowState.GitHubIssueConfirmationResult {
        let effect = await model.send(.performGitHubIssue(
            draft,
            proposalID: proposalID,
            proposedAt: proposedAt))
        switch effect {
        case .gitHubIssuePerformed(let outputURL):
            return .published(outputURL)
        case .gitHubIssueOutcomeUnknown(let message, let outputURL):
            return .outcomeUnknown(
                outputURL: outputURL,
                message: message)
        default:
            return .failed(model.state.lastActionError ?? L10n.text(
                "The issue could not be created. Nothing left Portavoz."))
        }
    }

    func openSkillOffer(
        _ offer: MeetingSkillOffer,
        detail: MeetingReviewReadModel
    ) {
        switch offer.kind {
        case .recapDraft, .emailRecapDraft, .secretGistPublish:
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
        switch effect {
        case .skillPerformed(let offer, let outputURL):
            guard offer.kind == .secretGistPublish else {
                return .succeeded
            }
            guard let outputURL else {
                return .gistOutcomeUnknown(
                    outputURL: nil,
                    message: L10n.text(
                        "This Gist attempt may have reached GitHub. Check your Gists before publishing again."))
            }
            return .gistPublished(outputURL)
        case .skillOutcomeUnknown(let offer, let message, let outputURL):
            guard offer.kind == .secretGistPublish else {
                return .failed(message)
            }
            return .gistOutcomeUnknown(
                outputURL: outputURL,
                message: message)
        default:
            return .failed(
                model.state.lastActionError
                    ?? L10n.text("The action could not run. Nothing left Portavoz."))
        }
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
