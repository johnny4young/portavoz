import ApplicationKit
import PortavozCore
import SwiftUI

struct MenuBarBriefConfirmSheet: View {
    let target: MenuBarModel.BriefConfirmTarget
    let confirm: () async -> MenuBarModel.BriefConfirmationResult
    let dismiss: @MainActor () -> Void

    @State private var executionRequestID: UUID?
    @State private var failure: String?

    private var running: Bool { executionRequestID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Prepare this brief")
                .font(.headline)
            ScrollView {
                MeetingBriefArtifactView(
                    brief: target.brief,
                    openMeeting: nil)
            }
            .frame(maxHeight: 340)
            .accessibilityIdentifier("menu-bar-brief-preview")
            capabilities
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("menu-bar-brief-confirm-error")
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                    .accessibilityIdentifier("menu-bar-brief-confirm-cancel")
                Button {
                    failure = nil
                    executionRequestID = UUID()
                } label: {
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Prepare brief")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(running)
                .accessibilityIdentifier("menu-bar-brief-confirm-submit")
            }
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(running)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-bar-brief-confirm-sheet")
        .task(id: executionRequestID) {
            guard executionRequestID != nil else { return }
            let result = await confirm()
            guard !Task.isCancelled else { return }
            if case .failed(let message) = result {
                failure = message
            }
            executionRequestID = nil
        }
    }

    private var capabilities: some View {
        HStack(spacing: 6) {
            capability("reads meeting material", id: "read")
            capability("writes a local draft", id: "write")
            capability("nothing leaves this Mac", id: "local")
        }
    }

    private func capability(
        _ label: LocalizedStringKey,
        id: String
    ) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(.tint)
            .accessibilityIdentifier("menu-bar-brief-capability-\(id)")
    }
}

struct MenuBarPreparedBriefSheet: View {
    let brief: MeetingBrief
    let openMeeting: @MainActor (MeetingID) -> Void
    let record: @MainActor () -> Void
    let dismiss: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Brief ready", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            ScrollView {
                MeetingBriefArtifactView(
                    brief: brief,
                    openMeeting: openMeeting)
            }
            .frame(maxHeight: 360)
            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .accessibilityIdentifier("menu-bar-brief-result-close")
                Button(action: record) {
                    Label("Record this meeting", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("menu-bar-brief-result-record")
            }
        }
        .padding(20)
        .frame(width: 500)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-bar-brief-result")
    }
}
