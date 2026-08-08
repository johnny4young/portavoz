import AppKit
import SwiftUI

struct CommitmentReminderStatusCard: View {
    let model: CommitmentReminderModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.subheadline.bold())
                Text(statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            statusControl
        }
        .padding(14)
        .background(
            statusColor.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commitment-reminder-card")
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.send(.applicationDidBecomeActive) }
        }
    }
}

private extension CommitmentReminderStatusCard {
    /// Deep link to the Notifications pane; falls back to the System Settings
    /// root if the pane URL scheme ever changes shape.
    func openNotificationSettings() {
        let pane = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        let root = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        if let pane, NSWorkspace.shared.open(pane) { return }
        NSWorkspace.shared.open(root)
    }

    @ViewBuilder var statusControl: some View {
        if model.state.phase == .failed {
            Button("Try again") {
                Task { await model.send(.retry) }
            }
            .accessibilityIdentifier("commitment-reminder-retry")
        } else {
            switch model.state.permission {
            case .unknown:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("commitment-reminder-checking")
            case .notDetermined:
                Button("Enable reminders") {
                    Task { await model.send(.enable) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.state.phase == .requestingPermission)
                .accessibilityIdentifier("commitment-reminder-enable")
            case .denied:
                // macOS never re-prompts a denied app; the only recovery is
                // the system pane, so offer the exact door plus a re-check.
                HStack(spacing: 8) {
                    Button("Open System Settings") {
                        openNotificationSettings()
                    }
                    .accessibilityIdentifier("commitment-reminder-open-settings")
                    Button("Check again") {
                        Task { await model.send(.retry) }
                    }
                    .accessibilityIdentifier("commitment-reminder-check-again")
                }
            case .enabled:
                enabledControl
            }
        }
    }

    @ViewBuilder var enabledControl: some View {
        if model.state.phase == .reconciling {
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("commitment-reminder-reconciling")
        } else {
            Label("On", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)
                .accessibilityIdentifier("commitment-reminder-enabled")
        }
    }

    var statusTitle: LocalizedStringKey {
        if model.state.phase == .failed {
            return "Reminders need attention"
        }
        return switch model.state.permission {
        case .unknown: "Checking reminders"
        case .notDetermined: "Private due-date reminders"
        case .denied: "Notifications are off"
        case .enabled: "Reminders are on"
        }
    }

    var statusDescription: LocalizedStringKey {
        if model.state.phase == .failed {
            return "Your confirmed commitments are safe. Try again."
        }
        return switch model.state.permission {
        case .unknown: "Checking Notification Center without asking for permission."
        case .notDetermined: "Get a generic local alert when confirmed work is due."
        case .denied: "Allow Portavoz notifications in System Settings, then check again."
        case .enabled: "Only confirmed commitments with a due date can alert you."
        }
    }

    var statusIcon: String {
        if model.state.phase == .failed { return "exclamationmark.triangle.fill" }
        return switch model.state.permission {
        case .unknown, .notDetermined: "bell.badge"
        case .denied: "bell.slash.fill"
        case .enabled: "bell.fill"
        }
    }

    var statusColor: Color {
        if model.state.phase == .failed { return .orange }
        return switch model.state.permission {
        case .unknown, .notDetermined: PVDesign.accent
        case .denied: .orange
        case .enabled: .green
        }
    }
}
