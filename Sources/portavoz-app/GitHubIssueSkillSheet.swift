import ApplicationKit
import Foundation
import PortavozCore
import SwiftUI

/// Review-first editor for exactly one pending action item. Repository entry
/// and immutable request review are separate stages; only the second stage can
/// authorize remote mutation.
struct GitHubIssueSkillSheet: View {
    let target: MeetingDetailFlowState.GitHubIssueTarget
    let prepare:
        @MainActor (String) async -> MeetingDetailFlowState.GitHubIssueDraftResult
    let confirm:
        @MainActor (GitHubIssueDraft, UUID, Date)
            async -> MeetingDetailFlowState.GitHubIssueConfirmationResult
    let copyText: @MainActor (String) -> Void
    let openURL: @MainActor (URL) -> Void
    let dismiss: @MainActor () -> Void

    @State private var repository = ""
    @State private var draft: GitHubIssueDraft?
    @State private var proposalID: UUID?
    @State private var proposedAt: Date?
    @State private var isPreparing = false
    @State private var isConfirming = false
    @State private var failure: String?
    @State private var completion:
        MeetingDetailFlowState.GitHubIssueConfirmationResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let completion {
                completionView(completion)
            } else if let draft {
                review(draft)
            } else {
                destination
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(isPreparing || isConfirming)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("github-issue-sheet")
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Create one GitHub issue", systemImage: "ladybug")
                .font(.headline)
            Text(target.actionItemText)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("github-issue-action-item")
            VStack(alignment: .leading, spacing: 6) {
                Text("Repository").font(.caption.weight(.semibold))
                TextField("owner/name", text: $repository)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("github-issue-repository")
                Text("Portavoz never guesses a repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Label(
                "Reviewing is local. Nothing leaves this Mac until you confirm the exact issue.",
                systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            failureView
            HStack {
                Spacer()
                Button(L10n.text("Cancel"), action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isPreparing)
                    .accessibilityIdentifier("github-issue-cancel")
                Button {
                    prepareDraft()
                } label: {
                    if isPreparing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Review issue")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isPreparing || repository.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("github-issue-review")
            }
        }
    }

    private func review(_ draft: GitHubIssueDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            reviewHeader(draft)
            reviewMaterial(draft)
            citationSummary(draft.citations)
            Label(
                "Confirming sends this title, body, and cited excerpts to this repository and creates one issue.",
                systemImage: "network.badge.shield.half.filled")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("github-issue-boundary")
            failureView
            reviewActions(draft)
        }
    }

    private func reviewHeader(_ draft: GitHubIssueDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Review the exact GitHub issue", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            HStack(spacing: 6) {
                Text(draft.repository.rawValue)
                Text("·")
                Text(GitHubIssueDraft.destinationHost)
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("github-issue-preview-repository")
        }
    }

    private func reviewMaterial(_ draft: GitHubIssueDraft) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Title").font(.caption.weight(.semibold))
            Text(draft.title)
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
                .accessibilityIdentifier("github-issue-preview-title")
            Text("Body").font(.caption.weight(.semibold))
            ScrollView {
                Text(draft.body)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("github-issue-preview-body")
            }
            .frame(maxHeight: 180)
            .padding(10)
            .background(
                .quaternary.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func reviewActions(_ draft: GitHubIssueDraft) -> some View {
        HStack {
            Button("Back") {
                self.draft = nil
                proposalID = nil
                proposedAt = nil
                failure = nil
            }
            .disabled(isConfirming)
            .accessibilityIdentifier("github-issue-back")
            Spacer()
            Button(L10n.text("Cancel"), action: dismiss)
                .keyboardShortcut(.cancelAction)
                .disabled(isConfirming)
                .accessibilityIdentifier("github-issue-cancel")
            Button {
                confirmDraft(draft)
            } label: {
                if isConfirming {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Create one issue")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isConfirming)
            .accessibilityIdentifier("github-issue-confirm")
        }
    }

    private func citationSummary(
        _ citations: [GitHubIssueCitation]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Evidence included").font(.caption.weight(.semibold))
            ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                Text("\(time(citation.timestamp)) · \(citation.speaker): \(citation.excerpt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("github-issue-citation-\(index)")
            }
        }
    }

    @ViewBuilder
    private func completionView(
        _ result: MeetingDetailFlowState.GitHubIssueConfirmationResult
    ) -> some View {
        switch result {
        case .published(let outputURL):
            Label("GitHub issue created", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .accessibilityIdentifier("github-issue-result-title")
            if let outputURL {
                resultURL(outputURL)
                resultActions(outputURL: outputURL)
            } else {
                Text("This exact issue was already recorded as completed.")
                    .font(.callout)
                resultActions(outputURL: nil)
            }
        case .outcomeUnknown(let outputURL, let message):
            Label(
                "Issue outcome unknown — check GitHub",
                systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("github-issue-result-title")
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("github-issue-result-message")
            if let outputURL { resultURL(outputURL) }
            resultActions(outputURL: outputURL)
        case .failed:
            EmptyView()
        }
    }

    private func resultURL(_ url: URL) -> some View {
        Text(url.absoluteString)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("github-issue-result-url")
    }

    private func resultActions(outputURL: URL?) -> some View {
        HStack {
            if let outputURL {
                Button(L10n.text("Copy link")) {
                    copyText(outputURL.absoluteString)
                }
                .accessibilityIdentifier("github-issue-result-copy")
                Button(L10n.text("Open")) { openURL(outputURL) }
                    .accessibilityIdentifier("github-issue-result-open")
            }
            Spacer()
            Button(L10n.text("Done"), action: dismiss)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("github-issue-result-dismiss")
        }
    }

    @ViewBuilder private var failureView: some View {
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("github-issue-error")
        }
    }

    private func prepareDraft() {
        isPreparing = true
        failure = nil
        let repository = repository
        Task {
            let result = await prepare(repository)
            isPreparing = false
            switch result {
            case .prepared(let draft):
                self.draft = draft
                proposalID = UUID()
                proposedAt = Date()
            case .failed(let message):
                failure = message
            }
        }
    }

    private func confirmDraft(_ draft: GitHubIssueDraft) {
        guard let proposalID, let proposedAt else { return }
        isConfirming = true
        failure = nil
        Task {
            let result = await confirm(draft, proposalID, proposedAt)
            isConfirming = false
            switch result {
            case .published, .outcomeUnknown:
                completion = result
            case .failed(let message):
                failure = message
            }
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
