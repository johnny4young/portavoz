import AppKit
import SwiftUI

/// The permission and confirmation moment are deliberately separate. The
/// final action appears only after one exact Reminders list is resolved.
struct ReminderDraftSheet: View {
    let model: ReminderDraftModel

    private var confirmation: ReminderDraftModel.Confirmation? {
        model.state.confirmation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create this reminder")
                .font(.headline)
            preview
            destination
            capabilities
            if let failure = confirmation?.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("reminder-draft-error")
            }
            controls
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminder-draft-sheet")
    }
}

private extension ReminderDraftSheet {
    var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reminder")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: confirmation?.offer.draft.title ?? "")
                .font(.title3.weight(.semibold))
                .accessibilityLabel(Text(
                    verbatim: confirmation?.offer.draft.title ?? ""))
                .accessibilityIdentifier("reminder-draft-preview-title")
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .accessibilityHidden(true)
                if let dueAt = confirmation?.offer.draft.dueAt {
                    Text(dueAt, format: .dateTime
                        .year().month().day().hour().minute())
                } else {
                    Text("No due date")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("reminder-draft-preview-due")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder var destination: some View {
        switch confirmation?.phase {
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking Reminders access without prompting…")
            }
            .accessibilityIdentifier("reminder-draft-checking")
        case .requestingAccess:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your Reminders choice…")
            }
            .accessibilityIdentifier("reminder-draft-requesting-access")
        case .ready, .executing:
            resolvedDestination
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder var resolvedDestination: some View {
        switch confirmation?.authorization {
        case .notDetermined:
            Label(
                "Portavoz will ask only when you choose Allow Reminders Access.",
                systemImage: "hand.raised.fill")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("reminder-draft-access-needed")
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Reminders access is off. Nothing was created.",
                    systemImage: "lock.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("reminder-draft-access-denied")
                HStack {
                    Button("Open System Settings", action: openReminderSettings)
                        .accessibilityIdentifier(
                            "reminder-draft-open-settings")
                    Button("Check again") {
                        Task { await model.refreshAccess() }
                    }
                    .accessibilityIdentifier("reminder-draft-check-again")
                }
            }
        case .fullAccess:
            VStack(alignment: .leading, spacing: 8) {
                if let target = confirmation?.target {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reminders list")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(verbatim: target.title)
                                .font(.callout.weight(.semibold))
                                .accessibilityLabel(Text(verbatim: target.title))
                                .accessibilityIdentifier(
                                    "reminder-draft-target-list")
                        }
                    }
                }
                Button("Refresh list") {
                    Task { await model.refreshAccess() }
                }
                .accessibilityIdentifier("reminder-draft-refresh-list")
            }
        case .unknown, nil:
            EmptyView()
        }
    }

    var capabilities: some View {
        HStack(spacing: 6) {
            capabilityChip("reads one confirmed commitment")
            capabilityChip("creates one local reminder")
            capabilityChip("nothing leaves this Mac")
        }
    }

    func capabilityChip(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(.tint)
    }

    var controls: some View {
        HStack {
            Spacer()
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)
                .accessibilityIdentifier("reminder-draft-cancel")
            primaryControl
        }
    }

    @ViewBuilder var primaryControl: some View {
        if confirmation?.phase == .requestingAccess
            || confirmation?.phase == .executing {
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("reminder-draft-running")
        } else if confirmation?.authorization == .notDetermined {
            Button("Allow Reminders Access") {
                Task { await model.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("reminder-draft-allow-access")
        } else if confirmation?.authorization == .fullAccess,
                  confirmation?.target != nil {
            Button("Create reminder") {
                Task { await model.confirm() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("reminder-draft-confirm")
        }
    }

    var isBusy: Bool {
        confirmation?.phase == .requestingAccess
            || confirmation?.phase == .executing
    }

    func openReminderSettings() {
        let pane = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        let root = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        if let pane, NSWorkspace.shared.open(pane) { return }
        NSWorkspace.shared.open(root)
    }
}
