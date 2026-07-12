import IntegrationsKit
import PortavozCore
import ServiceManagement
import SwiftUI

/// The resident menu-bar panel (design system 2b): a rich window, not a
/// flat menu — status at a glance, quick actions, the next meeting, and
/// recents. Portavoz keeps working with the library window closed (the
/// hotkey and this panel both live in the App, not the window).
struct MenuBarContent: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openWindow) private var openWindow
    @State private var recents: [Meeting] = []
    @State private var nextEvent: UpcomingEvent?

    private var recording: Bool { services.recording.phase == .recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            quickActions
            if let nextEvent {
                nextMeetingCard(nextEvent)
            }
            if !recents.isEmpty {
                recentsList
            }
            Divider().padding(.vertical, 4)
            footer
        }
        .padding(12)
        .frame(width: 320)
        .task {
            recents = Array(((try? await services.store.meetings()) ?? []).prefix(3))
            if !CalendarAttendeeSource.accessUndetermined {
                nextEvent = CalendarAttendeeSource().upcomingEvents().first
            }
        }
    }

    // MARK: Status

    private var statusHeader: some View {
        HStack(spacing: 10) {
            liveWaveform
            VStack(alignment: .leading, spacing: 1) {
                Text(recording ? "Recording…" : "Portavoz is idle")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text("100% local · 0 B to the network today")
                        .font(.caption2)
                }
                .foregroundStyle(Color.green)
            }
            Spacer()
        }
        .padding(.bottom, 10)
    }

    /// The bar's signature: a tiny waveform whose peak is your amber. Red
    /// while a meeting records — the glanceable "am I recording?" answer.
    private var liveWaveform: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array([0.4, 0.7, 1.0, 0.55].enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(peakColor(index))
                    .frame(width: 3, height: 20 * height)
            }
        }
        .frame(height: 20)
    }

    private func peakColor(_ index: Int) -> Color {
        if recording { return index == 2 ? .red : .red.opacity(0.5) }
        return index == 2 ? VoicePalette.me : .secondary
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 8) {
            if recording {
                quickAction("Stop", "stop.circle.fill", tint: .red) {
                    let services = self.services
                    Task { await services.recording.stop(services: services) }
                }
            } else {
                quickAction("Record", "record.circle", tint: .red) {
                    openMainWindow()
                    services.pendingRoute = .recording(nil)
                }
            }
            if UserDefaults.standard.bool(forKey: DictationController.defaultsKey) {
                quickAction("Dictate", "waveform", tint: PVDesign.accent) {
                    services.dictation.toggle(services: services)
                }
            }
            quickAction("Ask", "bubble.left.and.text.bubble.right", tint: .secondary) {
                openMainWindow()
                services.pendingRoute = .ask
            }
        }
        .padding(.bottom, 10)
    }

    private func quickAction(
        _ label: LocalizedStringKey, _ icon: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15))
                Text(label).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    // MARK: Next meeting

    private func nextMeetingCard(_ event: UpcomingEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.format("Next meeting · %@", relative(event.startDate)))
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(VoicePalette.me)
            Text(event.title).font(.callout.weight(.medium)).lineLimit(1)
            Button {
                openMainWindow()
                services.pendingRoute = .recording(event)
            } label: {
                Text("Record when it starts")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(VoicePalette.me.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(VoicePalette.me.opacity(0.25)))
        .padding(.bottom, 10)
    }

    // MARK: Recents

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
            ForEach(recents) { meeting in
                Button {
                    openMainWindow()
                    services.pendingRoute = .meeting(meeting.id)
                } label: {
                    HStack {
                        Text(meeting.title).lineLimit(1)
                        Spacer()
                        Text(relative(meeting.startedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Open Portavoz") { openMainWindow() }
            Spacer()
            LaunchAtLoginToggle()
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = AppLanguage.current.locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func openMainWindow() {
        // Re-open the library window if the user closed it, then front it.
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// `SMAppService.mainApp` wants the app in /Applications (it is — that's
/// the install story). State is re-read on every menu open; registration
/// errors surface by the toggle simply not flipping.
private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: $enabled)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .onChange(of: enabled) { _, wanted in
                do {
                    if wanted {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
    }
}
