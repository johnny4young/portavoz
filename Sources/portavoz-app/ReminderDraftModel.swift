import ApplicationKit
import Foundation
import Observation
import PortavozCore

enum AppReminderDraftAuthorization: Sendable, Equatable {
    case unknown
    case notDetermined
    case denied
    case fullAccess
}

/// Exact destination shown at confirmation. The opaque EventKit identity is
/// retained byte-for-byte; the title is display material, never a lookup key.
struct AppReminderDraftTarget: Sendable, Equatable {
    static let maximumIdentifierLength = 512
    static let maximumTitleLength = 256

    let identifier: String
    let title: String

    init?(identifier: String, title: String) {
        guard Self.hasBoundedContent(
            identifier,
            maximumLength: Self.maximumIdentifierLength),
              Self.hasBoundedContent(
                title,
                maximumLength: Self.maximumTitleLength)
        else { return nil }
        self.identifier = identifier
        self.title = title
    }

    private static func hasBoundedContent(
        _ value: String,
        maximumLength: Int
    ) -> Bool {
        guard value.utf8.prefix(maximumLength + 1).count <= maximumLength
        else { return false }
        return value.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}

struct ReminderDraftExecutionRequest: Equatable, Sendable {
    let offer: ReminderDraftOffer
    let proposalID: UUID
    let target: AppReminderDraftTarget
}

enum ReminderDraftExecutionResult: Equatable, Sendable {
    case succeeded(ReminderDraftSurfaceItem)
    case failed(String)
}

@MainActor
protocol ReminderDraftModelClient: AnyObject {
    func loadReminderDraftSurface(
        commitments: [Commitment]
    ) async throws -> ReminderDraftSurface
    func reminderDraftAuthorization() async -> AppReminderDraftAuthorization
    func requestReminderDraftAccess() async throws
        -> AppReminderDraftAuthorization
    func defaultReminderDraftTarget() async throws -> AppReminderDraftTarget?
    func performReminderDraft(
        _ request: ReminderDraftExecutionRequest
    ) async throws -> ReminderDraftExecutionResult
    func dismissReminderDraftOffer(_ offer: ReminderDraftOffer) async throws
}

/// Per-window proposal state. It never owns EventKit, storage, or a TCC prompt;
/// each explicit action crosses the narrow client owned by AppServices.
@MainActor
@Observable
final class ReminderDraftModel {
    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    enum ConfirmationPhase: Equatable {
        case preparing
        case ready
        case requestingAccess
        case executing
    }

    struct Confirmation: Equatable, Identifiable {
        var id: UUID { proposalID }
        let proposalID: UUID
        let offer: ReminderDraftOffer
        var authorization: AppReminderDraftAuthorization
        var target: AppReminderDraftTarget?
        var phase: ConfirmationPhase
        var failure: String?
    }

    struct State: Equatable {
        fileprivate(set) var loadPhase = LoadPhase.idle
        fileprivate(set) var items: [CommitmentID: ReminderDraftSurfaceItem] = [:]
        fileprivate(set) var confirmation: Confirmation?
        fileprivate(set) var surfaceFailure: String?
    }

    private(set) var state = State()

    private let client: any ReminderDraftModelClient
    private var loadRequestID = UUID()

    init(client: any ReminderDraftModelClient) {
        self.client = client
    }

    func load(commitments: [Commitment]) async {
        let requestID = UUID()
        loadRequestID = requestID
        state.loadPhase = .loading
        state.surfaceFailure = nil
        do {
            let surface = try await client.loadReminderDraftSurface(
                commitments: commitments)
            guard loadRequestID == requestID, !Task.isCancelled else { return }
            guard let items = Self.uniqueItems(surface.items) else {
                state.items = [:]
                state.loadPhase = .failed
                state.surfaceFailure = Self.surfaceLoadFailure
                return
            }
            state.items = items
            state.loadPhase = .loaded
        } catch is CancellationError {
            // A newer Radar page owns presentation.
        } catch {
            guard loadRequestID == requestID, !Task.isCancelled else { return }
            state.items = [:]
            state.loadPhase = .failed
            state.surfaceFailure = Self.surfaceLoadFailure
        }
    }

    func open(_ commitmentID: CommitmentID) async {
        guard let offer = state.items[commitmentID]?.offer else { return }
        let proposalID = UUID()
        state.confirmation = Confirmation(
            proposalID: proposalID,
            offer: offer,
            authorization: .unknown,
            target: nil,
            phase: .preparing,
            failure: nil)
        await refreshAuthorization(
            proposalID: proposalID,
            requestingAccess: false)
    }

    func requestAccess() async {
        guard let confirmation = state.confirmation,
              confirmation.phase == .ready,
              confirmation.authorization == .notDetermined
        else { return }
        await refreshAuthorization(
            proposalID: confirmation.proposalID,
            requestingAccess: true)
    }

    func refreshAccess() async {
        guard let confirmation = state.confirmation,
              confirmation.phase == .ready
        else { return }
        await refreshAuthorization(
            proposalID: confirmation.proposalID,
            requestingAccess: false)
    }

    func confirm() async {
        guard var confirmation = state.confirmation,
              confirmation.phase == .ready,
              confirmation.authorization == .fullAccess,
              let target = confirmation.target
        else { return }
        confirmation.phase = .executing
        confirmation.failure = nil
        state.confirmation = confirmation
        let proposalID = confirmation.proposalID
        do {
            let result = try await client.performReminderDraft(
                ReminderDraftExecutionRequest(
                    offer: confirmation.offer,
                    proposalID: proposalID,
                    target: target))
            guard state.confirmation?.proposalID == proposalID,
                  !Task.isCancelled
            else { return }
            switch result {
            case .succeeded(let item):
                guard item.commitmentID == confirmation.offer.commitment.id,
                      item.offer == nil,
                      item.receipt?.state == .succeeded
                else {
                    failConfirmation(
                        proposalID: proposalID,
                        message: L10n.text(
                            "The reminder result could not be verified. Check Reminders before trying again."))
                    return
                }
                state.items[item.commitmentID] = item
                state.confirmation = nil
            case .failed(let message):
                failConfirmation(
                    proposalID: proposalID,
                    message: message)
            }
        } catch is CancellationError {
            // The route disappeared; ExecuteSkill owns durable cancellation.
        } catch {
            failConfirmation(
                proposalID: proposalID,
                message: L10n.text(
                    "Portavoz could not verify whether the reminder was created. Check Reminders before retrying."))
        }
    }

    func cancel() {
        guard state.confirmation?.phase != .executing else { return }
        state.confirmation = nil
    }

    func dismiss(_ commitmentID: CommitmentID) async {
        guard let current = state.items[commitmentID],
              let offer = current.offer
        else { return }
        do {
            try await client.dismissReminderDraftOffer(offer)
            guard !Task.isCancelled,
                  state.items[commitmentID]?.offer == offer
            else { return }
            state.items[commitmentID] = ReminderDraftSurfaceItem(
                commitmentID: commitmentID,
                offer: nil,
                receipt: current.receipt)
        } catch is CancellationError {
            return
        } catch {
            state.surfaceFailure = L10n.text(
                "Could not dismiss this reminder suggestion.")
        }
    }

    func clearSurfaceFailure() {
        state.surfaceFailure = nil
    }
}

private extension ReminderDraftModel {
    static var surfaceLoadFailure: String {
        L10n.text(
            "Reminder suggestions are unavailable. Your commitments are unchanged. Reopen Radar to try again.")
    }

    static func uniqueItems(
        _ items: [ReminderDraftSurfaceItem]
    ) -> [CommitmentID: ReminderDraftSurfaceItem]? {
        var result: [CommitmentID: ReminderDraftSurfaceItem] = [:]
        for item in items {
            guard result[item.commitmentID] == nil else { return nil }
            result[item.commitmentID] = item
        }
        return result
    }

    func refreshAuthorization(
        proposalID: UUID,
        requestingAccess: Bool
    ) async {
        guard var confirmation = state.confirmation,
              confirmation.proposalID == proposalID
        else { return }
        confirmation.phase = requestingAccess ? .requestingAccess : .preparing
        confirmation.failure = nil
        state.confirmation = confirmation
        do {
            let authorization = if requestingAccess {
                try await client.requestReminderDraftAccess()
            } else {
                await client.reminderDraftAuthorization()
            }
            guard state.confirmation?.proposalID == proposalID,
                  !Task.isCancelled
            else { return }
            let target: AppReminderDraftTarget? = if authorization == .fullAccess {
                try await client.defaultReminderDraftTarget()
            } else {
                nil
            }
            guard var current = state.confirmation,
                  current.proposalID == proposalID,
                  !Task.isCancelled
            else { return }
            current.authorization = authorization
            current.target = target
            current.phase = .ready
            if authorization == .fullAccess, target == nil {
                current.failure = L10n.text(
                    "Portavoz could not find your default Reminders list. Choose one in Reminders, then check again.")
            }
            state.confirmation = current
        } catch is CancellationError {
            return
        } catch {
            failConfirmation(
                proposalID: proposalID,
                message: L10n.text(
                    "Reminders access could not be checked. Try again."))
        }
    }

    func failConfirmation(proposalID: UUID, message: String) {
        guard var confirmation = state.confirmation,
              confirmation.proposalID == proposalID
        else { return }
        confirmation.phase = .ready
        confirmation.failure = message
        state.confirmation = confirmation
    }
}
