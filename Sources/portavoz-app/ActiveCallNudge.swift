import AppKit
import PortavozCore
import SwiftUI

enum ActiveCallNudgePreferences {
    static let enabledKey = "activeCallNudgeEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil { return true }
        return defaults.bool(forKey: enabledKey)
    }
}

/// Passive active-call detector and floating one-click banner. Watches Core
/// Audio's process-object list for meeting apps actively using the microphone
/// without reading audio samples or requiring calendar access.
@MainActor
final class ActiveCallNudgeController {
    private var loop: Task<Void, Never>?
    private var autoDismissTask: Task<Void, Never>?
    private var detector = ActiveCallDetector()
    private var panel: NSPanel?
    private var shownNudge: ActiveCallNudge?
    private weak var services: AppServices?
    private let signalSource: @MainActor () -> [ActiveCallSignal]

    init(signalSource: @escaping @MainActor () -> [ActiveCallSignal] = MeetingAppDetector.activeCallSignals) {
        self.signalSource = signalSource
    }

    func start(services: AppServices) {
        guard loop == nil,
              !ProcessInfo.processInfo.arguments.contains("-use-temp-store")
        else { return }
        self.services = services
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func pollOnce() async {
        guard let services else { return }
        let nudge = poll(
            enabled: ActiveCallNudgePreferences.isEnabled(in: services.defaults),
            isRecording: services.recording.phase == .recording
                || services.recording.phase == .preparing,
            at: Date())
        if let nudge {
            if shownNudge != nudge {
                show(nudge)
            }
        } else if panel != nil {
            close()
        }
    }

    /// One detection step. Signals are read even while recording so the
    /// detector keeps the recorded call suppressed after the recording stops.
    func poll(enabled: Bool, isRecording: Bool, at now: Date) -> ActiveCallNudge? {
        guard enabled else {
            detector = ActiveCallDetector()
            return nil
        }
        return detector.observe(signals: signalSource(), isRecording: isRecording, at: now)
    }

    func accept(at now: Date) {
        detector.recordAccepted(at: now)
        close()
    }

    func dismiss(at now: Date) {
        detector.dismiss(at: now)
        close()
    }

    private func show(_ nudge: ActiveCallNudge) {
        close()
        shownNudge = nudge
        let content = ActiveCallBannerView(
            appName: nudge.appName,
            onRecord: { [weak self] in
                guard let self else { return }
                self.services?.pendingRoute = .recording(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.accept(at: Date())
            },
            onDismiss: { [weak self] in self?.dismiss(at: Date()) })

        let panel = ActiveCallBannerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = UITestWindowPlacement.floatingPanelLevel()
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: AnyView(content))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 376, y: frame.maxY - 80))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(120))
            if let self, self.panel === panel { self.dismiss(at: Date()) }
        }
    }

    private func close() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        panel?.orderOut(nil)
        panel = nil
        shownNudge = nil
    }
}

private final class ActiveCallBannerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct ActiveCallBannerView: View {
    let appName: String
    let onRecord: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.badge.waveform.fill")
                .font(.title3)
                .foregroundStyle(PVDesign.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.format("Call in %@", appName))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("Record call?")
                    .font(.caption)
                    .foregroundStyle(.ink3)
            }
            Spacer(minLength: 8)
            Button(action: onRecord) {
                Label("Record", systemImage: PVSymbol.record)
                    .font(.caption)
            }
            .buttonStyle(.pvPrimary)
            .controlSize(.small)
            .accessibilityIdentifier("active-call-record")
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.ink3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss call nudge")
            .accessibilityIdentifier("active-call-dismiss")
            .help("Dismiss call nudge")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Settings › General › Agenda: pre-meeting calendar banner and passive
/// active-call detection nudge.
struct SettingsAgendaSection: View {
    @AppStorage("meetingReminderMinutes") private var reminderMinutes = 5
    @AppStorage(ActiveCallNudgePreferences.enabledKey) private var activeCallNudgeEnabled = true

    var body: some View {
        Section("Agenda") {
            Picker("Remind me before meetings", selection: $reminderMinutes) {
                Text("Off").tag(0)
                Text("3 minutes before").tag(3)
                Text("5 minutes before").tag(5)
                Text("10 minutes before").tag(10)
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "A floating banner appears before your next calendar meeting — one click starts a recording linked to it. Needs calendar access."
            )
            .font(.caption)
            .foregroundStyle(.ink3)

            Toggle("Offer to record active calls", isOn: $activeCallNudgeEnabled)
                .accessibilityIdentifier("settings-active-call-nudge")
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Shows a one-click banner when Zoom, Teams, Slack, or a browser call starts — even without a calendar event."
            )
            .font(.caption)
            .foregroundStyle(.ink3)
        }
    }
}
