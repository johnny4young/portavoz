import ApplicationKit

extension MeetingDetailModel {
    func prepareGitHubIssue(
        _ request: PrepareGitHubIssueDraftRequest
    ) async -> Effect? {
        do {
            let draft = try await client.prepareMeetingDetailGitHubIssueDraft(request)
            recordLastActionError(nil)
            return .gitHubIssuePrepared(draft)
        } catch GitHubIssueSkillError.invalidRepository {
            recordLastActionError(L10n.text(
                "Enter a GitHub repository as owner/name."))
        } catch GitHubIssueSkillError.staleSummary {
            recordLastActionError(L10n.text(
                "The transcript changed. Regenerate the summary before creating an issue."))
        } catch {
            recordLastActionError(L10n.text(
                "This action item does not have current evidence for an issue draft."))
        }
        return nil
    }

    func performGitHubIssue(
        _ context: GitHubIssueExecutionContext
    ) async -> Effect? {
        do {
            let result = try await client.performMeetingDetailGitHubIssue(
                context.draft,
                proposalID: context.proposalID,
                proposedAt: context.proposedAt)
            return await publishGitHubIssueResult(result)
        } catch {
            recordLastActionError(UseCaseErrorMessages.describe(error))
            return nil
        }
    }

    private func publishGitHubIssueResult(
        _ result: MeetingDetailSkillExecutionResult
    ) async -> Effect? {
        switch result {
        case .succeeded(let outputURL):
            recordLastActionError(nil)
            _ = await send(.loadSkillOffers)
            return .gitHubIssuePerformed(outputURL: outputURL)
        case .retryableFailure(let message):
            recordLastActionError(message)
            _ = await send(.loadSkillOffers)
            return nil
        case .outcomeUnknown(let message, let outputURL):
            recordLastActionError(nil)
            _ = await send(.loadSkillOffers)
            return .gitHubIssueOutcomeUnknown(
                message: message,
                outputURL: outputURL)
        }
    }
}
