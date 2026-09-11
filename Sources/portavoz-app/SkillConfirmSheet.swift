import AppKit
import ApplicationKit
import PortavozCore
import SwiftUI

/// Q12/D316 — the confirmation moment. The sheet shows the EXACT artifact the
/// skill will produce and the capabilities it declares; confirming is the only
/// way an effect runs, and the durable receipt is written before it does.
struct SkillConfirmSheet: View {
    let target: MeetingDetailFlowState.SkillConfirmTarget
    let confirm: () async -> MeetingDetailFlowState.SkillConfirmationResult
    let copyText: @MainActor (String) -> Void
    let openURL: @MainActor (URL) -> Void
    let dismiss: @MainActor () -> Void

    @State private var running = false
    @State private var failure: String?
    @State private var completion: MeetingDetailFlowState.SkillConfirmationResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let completion {
                gistResult(completion)
            } else {
                confirmation
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(running)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skill-confirm-sheet")
    }

    @ViewBuilder private var confirmation: some View {
        Text(title).font(.headline)
        preview
        capabilities
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("skill-confirm-error")
        }
        HStack {
            Spacer()
            Button(L10n.text("Cancel"), action: dismiss)
                .keyboardShortcut(.cancelAction)
                .disabled(running)
                .accessibilityIdentifier("skill-confirm-cancel")
            Button {
                runConfirmation()
            } label: {
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Text(confirmTitle)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(running)
            .accessibilityIdentifier("skill-confirm-submit")
        }
    }

    @ViewBuilder
    private func gistResult(
        _ result: MeetingDetailFlowState.SkillConfirmationResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch result {
            case .gistPublished(let url):
                Label(L10n.text("Gist published"), systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("gist-result-title")
                gistResultURL(url)
                gistResultActions(outputURL: url)
            case .gistOutcomeUnknown(let outputURL, let message):
                Label(
                    L10n.text("Publication outcome unknown — check GitHub"),
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("gist-result-title")
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("gist-result-message")
                if let outputURL {
                    gistResultURL(outputURL)
                }
                gistResultActions(outputURL: outputURL)
            case .succeeded, .failed:
                EmptyView()
            }
        }
    }

    private func gistResultURL(_ url: URL) -> some View {
        Text(url.absoluteString)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("gist-result-url")
    }

    private func gistResultActions(outputURL: URL?) -> some View {
        HStack {
            if let outputURL {
                Button(L10n.text("Copy link")) {
                    copyText(outputURL.absoluteString)
                }
                .accessibilityIdentifier("gist-result-copy-link")
                Button(L10n.text("Open")) { openURL(outputURL) }
                    .accessibilityIdentifier("gist-result-open-link")
            }
            Spacer()
            Button(L10n.text("Done"), action: dismiss)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("gist-result-dismiss")
        }
    }

    private func runConfirmation() {
        running = true
        failure = nil
        Task {
            let result = await confirm()
            running = false
            switch result {
            case .succeeded:
                dismiss()
            case .gistPublished, .gistOutcomeUnknown:
                completion = result
            case .failed(let message):
                failure = message
            }
        }
    }

    @ViewBuilder private var preview: some View {
        switch target.preview {
        case .recap(let subject, let body),
             .emailDraft(let subject, let body):
            VStack(alignment: .leading, spacing: 6) {
                Text(subject)
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("skill-confirm-preview-subject")
                ScrollView {
                    Text(body)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("skill-confirm-preview-body")
                }
                .frame(maxHeight: 220)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                if target.offer.kind == .emailRecapDraft {
                    Label(
                        emailRecipientPolicy,
                        systemImage: "person.crop.circle.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(emailRecipientPolicy)
                        .accessibilityIdentifier("skill-confirm-email-recipient-policy")
                    Label(
                        emailBoundary,
                        systemImage: "envelope.open")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(emailBoundary)
                        .accessibilityIdentifier("skill-confirm-email-boundary")
                }
            }
        case .secretGist(let draft):
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.description)
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("skill-confirm-preview-subject")
                HStack(spacing: 6) {
                    Text(draft.filename)
                    Text("·")
                    Text(SecretGistDraft.destinationHost)
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("skill-confirm-gist-destination")
                ReadOnlySkillDocumentText(text: draft.markdown)
                .frame(maxHeight: 220)
                .padding(10)
                .background(
                    .quaternary.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 7))
                Label(
                    gistBoundary,
                    systemImage: "network.badge.shield.half.filled")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(gistBoundary)
                    .accessibilityIdentifier("skill-confirm-gist-boundary")
            }
        case .packageExport(let meetingTitle, let destination):
            VStack(alignment: .leading, spacing: 4) {
                Text(meetingTitle).font(.callout.weight(.semibold))
                Text(destination)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("skill-confirm-preview-destination")
                Text("Text only — audio never enters the package.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var capabilities: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(capabilityLabels, id: \.self) { capabilityChip($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(capabilityLabels, id: \.self) { capabilityChip($0) }
            }
        }
    }

    private var capabilityLabels: [String] {
        let effect = switch target.offer.kind {
        case .recapDraft: L10n.text("writes a local draft")
        case .emailRecapDraft: L10n.text("hands text to your email app")
        case .secretGistPublish: L10n.text("creates one secret GitHub Gist")
        case .packageExport: L10n.text("writes one local file")
        }
        let boundary = switch target.offer.kind {
        case .emailRecapDraft: L10n.text("you still press Send")
        case .secretGistPublish: L10n.text("the full document leaves this Mac")
        case .recapDraft, .packageExport: L10n.text("nothing leaves this Mac")
        }
        return [L10n.text("reads meeting material"), effect, boundary]
    }

    private func capabilityChip(_ label: String) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(.tint)
    }

    private var title: String {
        switch target.offer.kind {
        case .recapDraft: L10n.text("Draft this recap")
        case .emailRecapDraft: L10n.text("Open this email draft")
        case .secretGistPublish: L10n.text("Publish this secret Gist")
        case .packageExport: L10n.text("Export this package")
        }
    }

    private var confirmTitle: String {
        switch target.offer.kind {
        case .recapDraft: L10n.text("Copy draft to clipboard")
        case .emailRecapDraft: L10n.text("Open email draft")
        case .secretGistPublish: L10n.text("Publish secret Gist")
        case .packageExport: L10n.text("Write package")
        }
    }

    private var emailRecipientPolicy: String {
        L10n.text("No recipients — you choose them in your email app.")
    }

    private var emailBoundary: String {
        L10n.text(
            "Opening the draft hands this text to your email app, which may save or sync it. Portavoz never sends it.")
    }

    private var gistBoundary: String {
        L10n.text(
            "Publishes this full document as a secret (unlisted) GitHub Gist. Anyone with the link can read it.")
    }
}

/// A viewport-backed TextKit surface keeps an exact long transcript selectable
/// without asking one monolithic SwiftUI `Text` to lay out the whole document.
private struct ReadOnlySkillDocumentText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.setAccessibilityIdentifier("skill-confirm-preview-body")

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text
        else { return }
        textView.string = text
    }
}
