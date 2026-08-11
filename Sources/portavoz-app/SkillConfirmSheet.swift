import ApplicationKit
import PortavozCore
import SwiftUI

/// Q12/D316 — the confirmation moment. The sheet shows the EXACT artifact the
/// skill will produce and the capabilities it declares; confirming is the only
/// way an effect runs, and the durable receipt is written before it does.
struct SkillConfirmSheet: View {
    let target: MeetingDetailFlowState.SkillConfirmTarget
    let confirm: () async -> MeetingDetailFlowState.SkillConfirmationResult
    let dismiss: @MainActor () -> Void

    @State private var running = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    running = true
                    failure = nil
                    Task {
                        let result = await confirm()
                        running = false
                        switch result {
                        case .succeeded:
                            dismiss()
                        case .failed(let message):
                            failure = message
                        }
                    }
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
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(running)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skill-confirm-sheet")
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
        case .packageExport: L10n.text("writes one local file")
        }
        let boundary = target.offer.kind == .emailRecapDraft
            ? L10n.text("you still press Send")
            : L10n.text("nothing leaves this Mac")
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
        case .packageExport: L10n.text("Export this package")
        }
    }

    private var confirmTitle: String {
        switch target.offer.kind {
        case .recapDraft: L10n.text("Copy draft to clipboard")
        case .emailRecapDraft: L10n.text("Open email draft")
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
}
