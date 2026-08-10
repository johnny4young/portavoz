import ApplicationKit
import Foundation
import PortavozCore

extension AppServices {
    static func makeReminderDraftPlatform(
        usesTemporaryStore: Bool
    ) -> any AppReminderDraftPlatform {
        usesTemporaryStore
            ? UITestReminderDraftPlatform()
            : AppReminderDraftEventKitAdapter()
    }

    func makeReminderDraftModel() -> ReminderDraftModel {
        ReminderDraftModel(client: self)
    }
}

extension AppServices: ReminderDraftModelClient {
    func loadReminderDraftSurface(
        commitments: [Commitment]
    ) async throws -> ReminderDraftSurface {
        try await LoadReminderDraftSurface(store: store).execute(
            try ReminderDraftSurfaceRequest(commitments: commitments))
    }

    func reminderDraftAuthorization() async -> AppReminderDraftAuthorization {
        await reminderDraftPlatform.authorizationStatus()
    }

    func requestReminderDraftAccess() async throws
        -> AppReminderDraftAuthorization {
        try await reminderDraftPlatform.requestFullAccess()
    }

    func defaultReminderDraftTarget() async throws -> AppReminderDraftTarget? {
        await reminderDraftPlatform.defaultTarget()
    }

    func dismissReminderDraftOffer(_ offer: ReminderDraftOffer) async throws {
        try await DismissReminderDraftOffer(store: store).execute(offer)
    }

    func performReminderDraft(
        _ request: ReminderDraftExecutionRequest
    ) async throws -> ReminderDraftExecutionResult {
        let current = try await store.commitmentContinuityEnvelope(
            for: request.offer.commitment.id).commitment
        guard current == request.offer.commitment else {
            return .failed(staleReminderDraftFailure)
        }
        let surface = try await LoadReminderDraftSurface(store: store).execute(
            try ReminderDraftSurfaceRequest(commitments: [current]))
        guard surface.items.first?.offer == request.offer else {
            return .failed(staleReminderDraftFailure)
        }
        guard await reminderDraftPlatform.authorizationStatus() == .fullAccess,
              await reminderDraftPlatform.target(
                identifier: request.target.identifier) == request.target
        else {
            return .failed(L10n.text(
                "Reminders access or the destination changed. Check again before creating it."))
        }

        let key = request.offer.offerKey
        let existing = try await store.skillExecution(idempotencyKey: key)
        guard let proposalID = ReminderDraftProposalFactory.durableProposalID(
            requested: request.proposalID,
            existing: existing,
            idempotencyKey: key),
              let built = ReminderDraftProposalFactory.proposal(
                proposalID: proposalID,
                offer: request.offer,
                at: Date())
        else { return .failed(staleReminderDraftFailure) }

        let outcome = try await ExecuteSkill(
            claims: store,
            policy: store,
            effects: [
                ReminderDraftSkill.id: ReminderDraftEffect(
                    delivery: AppBoundReminderDraftDelivery(
                        platform: reminderDraftPlatform,
                        target: request.target))
            ]
        ).execute(ExecuteSkillRequest(
            proposal: built.proposal,
            isConfirmedByUser: true,
            egressIsPermitted: false,
            idempotencyKey: built.idempotencyKey))
        switch outcome {
        case .performed, .alreadySettled(.succeeded):
            return try await settledReminderDraftResult(commitment: current)
        case .failed(.external):
            return .failed(reminderDraftUnverifiedFailure)
        case .failed:
            return .failed(L10n.text(
                "The reminder was not created. You can retry this exact draft."))
        case .refused(.allSkillsPaused):
            return .failed(L10n.text("Skills are paused in Settings."))
        case .refused(.skillDisabled):
            return .failed(L10n.text("This skill is disabled in Settings."))
        case .alreadySettled, .refused, .rejected:
            return .failed(staleReminderDraftFailure)
        }
    }

    private func settledReminderDraftResult(
        commitment: Commitment
    ) async throws -> ReminderDraftExecutionResult {
        let surface = try await LoadReminderDraftSurface(store: store).execute(
            try ReminderDraftSurfaceRequest(commitments: [commitment]))
        guard let item = surface.items.first,
              item.offer == nil,
              item.receipt?.state == .succeeded
        else { return .failed(staleReminderDraftFailure) }
        return .succeeded(item)
    }

    private var staleReminderDraftFailure: String {
        L10n.text(
            "This reminder draft changed or already ran. Open a fresh preview.")
    }

    private var reminderDraftUnverifiedFailure: String {
        L10n.text(
            "Portavoz could not verify whether the reminder was created. Check Reminders before retrying.")
    }
}

private struct AppBoundReminderDraftDelivery: ReminderDraftDelivering {
    let platform: any AppReminderDraftPlatform
    let target: AppReminderDraftTarget

    func deliver(_ draft: ReminderDraft) async throws {
        try await platform.deliver(draft, to: target)
    }
}

/// Disposable-app fixture. It starts undetermined and grants only after the
/// production explicit permission action; host Reminders and TCC stay untouched.
private actor UITestReminderDraftPlatform: AppReminderDraftPlatform {
    private let resolvedTarget = AppReminderDraftTarget(
        identifier: "portavoz-ui-test-reminders-list",
        title: "Reminders")
    private var authorization = AppReminderDraftAuthorization.notDetermined
    private var delivered: [ReminderDraft] = []

    func authorizationStatus() -> AppReminderDraftAuthorization {
        authorization
    }

    func requestFullAccess() -> AppReminderDraftAuthorization {
        authorization = .fullAccess
        return authorization
    }

    func defaultTarget() -> AppReminderDraftTarget? {
        authorization == .fullAccess ? resolvedTarget : nil
    }

    func target(identifier: String) -> AppReminderDraftTarget? {
        guard authorization == .fullAccess,
              resolvedTarget?.identifier == identifier
        else { return nil }
        return resolvedTarget
    }

    func deliver(
        _ draft: ReminderDraft,
        to target: AppReminderDraftTarget
    ) throws {
        guard authorization == .fullAccess else {
            throw AppReminderDraftError.authorizationDenied
        }
        guard target == resolvedTarget else {
            throw AppReminderDraftError.staleTarget
        }
        delivered.append(draft)
    }
}
