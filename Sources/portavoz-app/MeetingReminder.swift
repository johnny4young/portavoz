import AppKit
import ApplicationKit
import IntegrationsKit
import PortavozCore
import SwiftUI

/// Proactive pre-meeting banner (M13b, closes the brief loop): a small
/// always-on-top, NON-ACTIVATING panel a few minutes before the next
/// calendar meeting — "starts in 5 min", one click starts the linked
/// recording. No notification permission needed (it's a floating panel,
/// same approach as the recording HUD); calendar access is the only gate.
@MainActor
final class MeetingReminderController {
    private var loop: Task<Void, Never>?
    private var reminded: Set<String> = []
    private var panel: NSPanel?
    private weak var services: AppServices?

    /// Checks every minute; the pure `ReminderPolicy` decides. One banner
    /// per event per app session — dismissing it never re-nags.
    func start(services: AppServices) {
        guard loop == nil,
            !ProcessInfo.processInfo.arguments.contains("-use-temp-store")
        else { return }
        self.services = services
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func check() {
        let lead = UserDefaults.standard.object(forKey: "meetingReminderMinutes") as? Int ?? 5
        let events = CalendarAttendeeSource().upcomingEvents()
        guard
            let due = ReminderPolicy.dueEvent(
                events: events, now: Date(), leadMinutes: lead, alreadyReminded: reminded)
        else { return }
        reminded.insert(due.id)
        show(due)
    }

    private func show(_ event: UpcomingEvent) {
        close()
        let minutes = max(1, Int((event.startDate.timeIntervalSinceNow / 60).rounded(.up)))
        let content = ReminderBannerView(
            event: event,
            minutesLeft: minutes,
            onRecord: { [weak self] in
                self?.services?.pendingRoute = .recording(event)
                NSApp.activate(ignoringOtherApps: true)
                self?.close()
            },
            onDismiss: { [weak self] in self?.close() })

        let panel = ReminderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: AnyView(content))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 396, y: frame.maxY - 80))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        // The banner is a nudge, not a modal: it leaves on its own once the
        // meeting is underway.
        Task { [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(180))
            if let self, self.panel === panel { self.close() }
        }
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Borderless panels refuse key status by default; the banner needs it so
/// its buttons land clicks without activating the app over the meeting.
private final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct ReminderBannerView: View {
    let event: UpcomingEvent
    let minutesLeft: Int
    let onRecord: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(PVDesign.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("Starts in \(minutesLeft) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onRecord) {
                Label("Record this meeting", systemImage: "record.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss — it will not remind you again for this meeting")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
