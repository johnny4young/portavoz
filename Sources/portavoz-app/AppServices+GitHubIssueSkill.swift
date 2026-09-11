import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

/// AUTO-4b/D434 — review-first GitHub issue composition. The exact draft is
/// rebuilt at confirmation before credentials, claims, receipts, or transport.
extension AppServices {
    func prepareMeetingDetailGitHubIssueDraft(
        _ request: PrepareGitHubIssueDraftRequest
    ) async throws -> GitHubIssueDraft {
        try await PrepareGitHubIssueDraft(
            library: QueryMeetingLibrary.local(store: store)
        ).execute(request)
    }

    func performMeetingDetailGitHubIssue(
        _ approvedDraft: GitHubIssueDraft,
        proposalID requestedProposalID: UUID,
        proposedAt: Date
    ) async throws -> MeetingDetailSkillExecutionResult {
        let currentDraft = try await prepareMeetingDetailGitHubIssueDraft(
            PrepareGitHubIssueDraftRequest(
                meetingID: approvedDraft.meetingID,
                actionItemID: approvedDraft.actionItemID,
                repository: approvedDraft.repository.rawValue))
        guard currentDraft == approvedDraft else {
            return .retryableFailure(L10n.text(
                "This issue draft changed. Review it again before publishing."))
        }
        let key = GitHubIssueCreateSkill.idempotencyKey(for: currentDraft)
        if let settled = try await existingGitHubIssueResult(key: key) {
            return settled
        }
        let proposalID = try await skillProposalID(
            requested: requestedProposalID,
            idempotencyKey: key)
        return try await executeGitHubIssueSkill(
            currentDraft,
            proposalID: proposalID,
            proposedAt: proposedAt,
            idempotencyKey: key)
    }

    private func executeGitHubIssueSkill(
        _ currentDraft: GitHubIssueDraft,
        proposalID: UUID,
        proposedAt: Date,
        idempotencyKey: String
    ) async throws -> MeetingDetailSkillExecutionResult {
        let proposal = GitHubIssueCreateSkill.proposal(
            id: proposalID,
            draft: currentDraft,
            proposedAt: proposedAt)
        let publisher = githubIssueSkillPublisher(
            proposalID: proposalID,
            draft: currentDraft)
        // Missing credentials are known before any durable claim or egress
        // receipt and may safely return to the review sheet.
        try await publisher.prepare()
        let outcome: SkillExecutionOutcome
        do {
            outcome = try await ExecuteSkill(
                claims: store,
                policy: store,
                effects: [
                    GitHubIssueCreateSkill.id: GitHubIssueCreateEffect(
                        draft: currentDraft,
                        publisher: publisher)
                ]
            ).execute(ExecuteSkillRequest(
                proposal: proposal,
                isConfirmedByUser: true,
                egressIsPermitted: true,
                offerKey: GitHubIssueCreateSkill.offerKey(
                    meetingID: currentDraft.meetingID,
                    actionItemID: currentDraft.actionItemID),
                idempotencyKey: idempotencyKey))
        } catch {
            guard await publisher.remoteAttemptStarted() else { throw error }
            return githubIssueOutcomeUnknown(
                outputURL: await publisher.outputURL())
        }
        let outputURL = await publisher.outputURL()
        switch outcome {
        case .performed, .alreadySettled(.succeeded):
            return .succeeded(outputURL: outputURL)
        case .failed(.external), .alreadySettled(.executing),
             .alreadySettled(.failed):
            return githubIssueOutcomeUnknown(outputURL: outputURL)
        case .refused(.allSkillsPaused):
            return .retryableFailure(L10n.text("Actions are paused in Settings."))
        case .refused(.skillDisabled):
            return .retryableFailure(L10n.text(
                "This action is disabled in Settings."))
        case .alreadySettled, .refused, .rejected, .failed:
            return .retryableFailure(L10n.text(
                "This issue could not be created. Nothing left Portavoz."))
        }
    }

    private func existingGitHubIssueResult(
        key: String
    ) async throws -> MeetingDetailSkillExecutionResult? {
        guard let record = try await store.skillExecution(idempotencyKey: key) else {
            return nil
        }
        switch record.state {
        case .succeeded:
            return .succeeded(outputURL: nil)
        case .executing, .failed:
            return githubIssueOutcomeUnknown(outputURL: nil)
        case .proposed, .previewed, .confirmed, .dismissed:
            return nil
        }
    }

    private func githubIssueOutcomeUnknown(
        outputURL: URL?
    ) -> MeetingDetailSkillExecutionResult {
        .outcomeUnknown(
            message: L10n.text(
                "GitHub may have created this issue. Check the repository before trying again."),
            outputURL: outputURL)
    }

    private func githubIssueSkillPublisher(
        proposalID: UUID,
        draft: GitHubIssueDraft
    ) -> AppGitHubIssueSkillPublisher {
        let eventID = DataEgressEventID(rawValue: proposalID)
        guard usesTemporaryMeetingStore else {
            return AppGitHubIssueSkillPublisher(
                repository: draft.repository,
                secrets: secrets,
                gateway: URLSessionDataEgressGateway(
                    session: AppGitHubIssueNetworkPolicy.makeSession(),
                    receiptRecorder: store,
                    makeEventID: { eventID }))
        }
        return AppGitHubIssueSkillPublisher(
            repository: draft.repository,
            disposableToken: "disposable-uitest-token",
            gateway: AppDisposableGitHubIssueEgressGateway(
                store: store,
                eventID: eventID,
                approvedDraft: draft))
    }
}

enum AppGitHubIssueNetworkPolicy {
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 20

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

/// Retains only attempt state and the transient provider URL. Neither the
/// credential nor reviewed meeting content enters a durable Skill receipt.
actor AppGitHubIssueSkillPublisher: GitHubIssuePublishing,
    AppMeetingSkillOutputReading {
    private let repository: GitHubRepository
    private let secrets: ManageSecrets?
    private let disposableToken: String?
    private let gateway: any DataEgressGateway
    private var exporter: GitHubIssuesExporter?
    private var didStartRemoteAttempt = false
    private var resultURL: URL?

    init(
        repository: GitHubRepository,
        secrets: ManageSecrets,
        gateway: any DataEgressGateway
    ) {
        self.repository = repository
        self.secrets = secrets
        disposableToken = nil
        self.gateway = gateway
    }

    init(
        repository: GitHubRepository,
        disposableToken: String,
        gateway: any DataEgressGateway
    ) {
        self.repository = repository
        secrets = nil
        self.disposableToken = disposableToken
        self.gateway = gateway
    }

    func prepare() async throws {
        guard exporter == nil else { return }
        let token: String
        if let disposableToken {
            token = disposableToken
        } else {
            guard let stored = try await secrets?.value(for: .gitHubToken),
                  !stored.isEmpty
            else { throw AppMeetingDocumentError.missingGitHubToken }
            token = stored
        }
        exporter = GitHubIssuesExporter(
            repository: repository.rawValue,
            token: token,
            gateway: gateway)
    }

    func publish(_ draft: GitHubIssueDraft) async throws -> URL {
        guard draft.repository == repository, let exporter else {
            throw GitHubIssueSkillError.invalidDraft
        }
        didStartRemoteAttempt = true
        do {
            let url = try await exporter.publish(
                title: draft.title,
                body: draft.body,
                meetingID: draft.meetingID)
            resultURL = url
            return url
        } catch {
            throw GitHubIssueSkillError.outcomeUnknown
        }
    }

    func remoteAttemptStarted() async -> Bool { didStartRemoteAttempt }
    func outputURL() async -> URL? { resultURL }
}

/// Deterministic real-app transport substitute. It verifies the exact approved
/// JSON and canonical egress metadata, receipts before response, and never
/// touches Keychain or the network.
private struct AppDisposableGitHubIssueEgressGateway: DataEgressGateway {
    let store: MeetingStore
    let eventID: DataEgressEventID
    let approvedDraft: GitHubIssueDraft

    func perform(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) async throws -> DataEgressResponse {
        let expectedPath = "/repos/\(approvedDraft.repository.owner)"
            + "/\(approvedDraft.repository.name)/issues"
        guard let url = networkRequest.url,
              url.scheme == "https",
              url.host == GitHubIssueDraft.destinationHost,
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.path == expectedPath,
              url.query == nil,
              url.fragment == nil,
              networkRequest.httpMethod == "POST",
              metadata.destination.url == url,
              let data = networkRequest.httpBody,
              let payload = try JSONSerialization.jsonObject(with: data)
                as? [String: String],
              payload == [
                "title": approvedDraft.title,
                "body": approvedDraft.body
              ],
              metadata.operation == .createGitHubIssue,
              metadata.dataClassification == .meetingActionItem,
              metadata.consentSource == .explicitGitHubIssuePublish,
              metadata.meetingID == approvedDraft.meetingID,
              metadata.providerDisclosure.providerID
                == GitHubIssueDraft.destinationHost
        else { throw GitHubIssueSkillError.invalidDraft }
        try await store.recordDataEgressEvent(DataEgressEvent(
            id: eventID,
            request: metadata,
            attemptedAt: Date()))
        let payloadData = Data(
            #"{"html_url":"https://github.com/portavoz/demo/issues/42"}"#.utf8)
        return DataEgressResponse(data: payloadData, statusCode: 201)
    }
}
