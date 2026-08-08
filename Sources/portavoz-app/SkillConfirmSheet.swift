import ApplicationKit
import PortavozCore
import SwiftUI

/// Q12/D316 — the confirmation moment. The sheet shows the EXACT artifact the
/// skill will produce and the capabilities it declares; confirming is the only
/// way an effect runs, and the durable receipt is written before it does.
struct SkillConfirmSheet: View {
    let target: MeetingDetailFlowState.SkillConfirmTarget
    let confirm: () async -> Bool
    let dismiss: @MainActor () -> Void

    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            preview
            capabilities
            HStack {
                Spacer()
                Button(L10n.text("Cancel"), action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button {
                    running = true
                    Task {
                        let done = await confirm()
                        running = false
                        if done { dismiss() }
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skill-confirm-sheet")
    }

    @ViewBuilder private var preview: some View {
        switch target.preview {
        case .recap(let subject, let body):
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
        HStack(spacing: 6) {
            capabilityChip(L10n.text("reads meeting material"))
            switch target.offer.kind {
            case .recapDraft:
                capabilityChip(L10n.text("writes a local draft"))
            case .packageExport:
                capabilityChip(L10n.text("writes one local file"))
            }
            capabilityChip(L10n.text("nothing leaves this Mac"))
        }
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
        case .packageExport: L10n.text("Export this package")
        }
    }

    private var confirmTitle: String {
        switch target.offer.kind {
        case .recapDraft: L10n.text("Copy draft to clipboard")
        case .packageExport: L10n.text("Write package")
        }
    }
}
