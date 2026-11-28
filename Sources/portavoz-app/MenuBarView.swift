import ApplicationKit
import PortavozCore
import ServiceManagement
import SwiftUI

/// The resident menu-bar panel: the live meeting while one records, Stop or
/// Record and Ask, the next meeting, recents with their voice strips, and the
/// app rows. Portavoz keeps working with the library window closed.
struct MenuBarContent: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openWindow) private var openWindow
    @State private var model: MenuBarModel

    init(model: MenuBarModel) {
        _model = State(initialValue: model)
    }

    private var recording: Bool { services.recording.phase == .recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recording {
                MenuBarLiveMeeting(controller: services.recording)
            }
            quickActions
            if let nextEvent = model.state.nextEvent {
                MenuBarDivider()
                nextMeeting(nextEvent)
            }
            let recents = model.state.meetings
            if !recents.isEmpty {
                MenuBarDivider()
                recentsList(recents)
            }
            MenuBarDivider()
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(width: 330)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-bar-panel")
        .task { await model.observe() }
        .task(id: model.state.briefPreparationRequest?.id) {
            await model.prepareRequestedBrief()
        }
        .sheet(item: briefConfirmationBinding) { target in
            MenuBarBriefConfirmSheet(
                target: target,
                confirm: { await model.confirmBrief(target) },
                dismiss: model.cancelBriefConfirmation)
        }
        .sheet(isPresented: preparedBriefBinding) {
            if let brief = model.state.preparedBrief {
                MenuBarPreparedBriefSheet(
                    brief: brief,
                    openMeeting: openPreparedMeeting,
                    record: { recordPreparedBrief(brief) },
                    dismiss: model.closePreparedBrief)
            }
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 8) {
            if recording {
                Button {
                    let services = self.services
                    Task { await services.recording.stop(services: services) }
                } label: {
                    Label("Stop", systemImage: PVSymbol.stop).frame(maxWidth: .infinity)
                }
                .buttonStyle(.pvStop)
                .accessibilityIdentifier("menu-bar-stop")
            } else {
                Button {
                    openMainWindow()
                    services.pendingRoute = .recording(nil)
                } label: {
                    RecordLabel("Record").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pvPrimary)
                .accessibilityIdentifier("menu-bar-record")
            }
            Button {
                openMainWindow()
                services.pendingRoute = .ask
            } label: {
                Label("Ask", systemImage: PVSymbol.ask).frame(maxWidth: .infinity)
            }
            .buttonStyle(.pvSecondary)
            .accessibilityIdentifier("menu-bar-ask")
        }
        .controlSize(.large)
        .padding(.horizontal, 4)
        .padding(.top, recording ? 10 : 0)
        .padding(.bottom, 12)
    }

    // MARK: Next meeting

    private func nextMeeting(_ event: UpcomingEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MenuBarCaption(text: L10n.format("Next · %@", MenuBarFormat.relative(event.startDate)))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PVDesign.ink)
                        .lineLimit(1)
                    Text(MenuBarFormat.eventDetail(event))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.ink3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                nextMeetingActions(event)
            }
            .padding(.horizontal, 6)
            if let failure = model.state.briefFailure {
                Text(failure)
                    .font(.caption2)
                    .cautionText()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .accessibilityIdentifier("menu-bar-brief-error")
            }
        }
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-bar-next-meeting")
    }

    private func nextMeetingActions(_ event: UpcomingEvent) -> some View {
        HStack(spacing: 8) {
            if let offer = model.state.briefOffer, offer.event.id == event.id {
                prepareBriefButton(offer)
                Button {
                    Task { await model.dismissBriefOffer(offer) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.ink3)
                .accessibilityLabel("Dismiss brief suggestion")
                .accessibilityIdentifier("menu-bar-brief-dismiss")
                .help("Don't suggest a brief for this event again")
            } else if model.state.preparedEventID == event.id {
                Label("Brief prepared", systemImage: PVSymbol.success)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PVDesign.ok)
                    .accessibilityIdentifier("menu-bar-brief-prepared")
            }
            // One recording at a time: the next meeting records once this one stops.
            if !recording {
                Button {
                    openMainWindow()
                    services.pendingRoute = .recording(event)
                } label: {
                    RecordLabel("Record")
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(PVDesign.ink)
                .accessibilityIdentifier("menu-bar-record-next")
            }
        }
        .fixedSize()
    }

    private func prepareBriefButton(_ offer: PreMeetingBriefOffer) -> some View {
        Button {
            model.requestBrief(offer)
        } label: {
            if model.state.briefPreparationRequest != nil {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Preparing…")
                }
            } else {
                Text("Prepare brief")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(PVDesign.green)
        .buttonStyle(.plain)
        .disabled(model.state.briefPreparationRequest != nil)
        .accessibilityIdentifier("menu-bar-brief-prepare")
    }

    // MARK: Recents

    private func recentsList(_ recents: [MenuBarMeeting]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarCaption(text: L10n.text("Recent"))
            ForEach(recents) { meeting in
                MenuBarRow(identifier: "menu-bar-recent-\(meeting.id.rawValue.uuidString)") {
                    openMainWindow()
                    services.pendingRoute = .meeting(meeting.id)
                } label: {
                    recentRow(meeting)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func recentRow(_ meeting: MenuBarMeeting) -> some View {
        HStack(spacing: 8) {
            Text(meeting.title)
                .lineLimit(1)
                .frame(width: 138, alignment: .leading)
            if let strip = model.state.recentStrips[meeting.id] {
                VoiceStrip(strip)
                    .frame(width: 36)
                    .accessibilityIdentifier("menu-bar-recent-strip")
            }
            Spacer(minLength: 4)
            if let pending = model.state.pendingByMeeting[meeting.id], pending > 0 {
                Label("\(pending)", systemImage: PVSymbol.automations)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(PVDesign.green)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(PVDesign.greenBg, in: Capsule())
            }
            Text(MenuBarFormat.started(meeting.startedAt))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.ink3)
                .fixedSize()
        }
        .frame(height: 34)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarRow(identifier: "menu-bar-open", action: openMainWindow) {
                Text("Open Portavoz")
            }
            LaunchAtLoginToggle()
                .padding(.horizontal, 10)
                .frame(height: 28)
            MenuBarRow(identifier: "menu-bar-quit") {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
            }
        }
    }

    private func openMainWindow() {
        // Re-open or front the one value-scoped primary library window.
        openWindow(id: "main", value: MainWindowIdentity.primary)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var briefConfirmationBinding:
        Binding<MenuBarModel.BriefConfirmTarget?> {
        Binding(
            get: { model.state.briefConfirmTarget },
            set: { if $0 == nil { model.cancelBriefConfirmation() } })
    }

    private var preparedBriefBinding: Binding<Bool> {
        Binding(
            get: { model.state.preparedBrief != nil },
            set: { if !$0 { model.closePreparedBrief() } })
    }

    private func openPreparedMeeting(_ meetingID: MeetingID) {
        model.closePreparedBrief()
        openMainWindow()
        services.pendingRoute = .meeting(meetingID)
    }

    private func recordPreparedBrief(_ brief: MeetingBrief) {
        model.closePreparedBrief()
        openMainWindow()
        services.pendingRoute = .recording(brief.event)
    }
}

/// The meeting being recorded: the kicker and clock, its title, the strip up
/// to now and who is speaking. Only this view reads the clock and the voices.
private struct MenuBarLiveMeeting: View {
    let controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                RecordingKicker(startedAt: controller.startedAt, identifier: "menu-bar-kicker")
                Spacer(minLength: 8)
                ElapsedClockText(
                    startedAt: controller.startedAt, style: .clock(size: 30), identifier: "menu-bar-elapsed-time")
            }
            Text(controller.title ?? L10n.text("Recording"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PVDesign.ink)
                .lineLimit(1)
                .padding(.top, 2)
                .accessibilityIdentifier("menu-bar-recording-title")
            MenuBarLiveVoices(model: controller.liveVoices)
                .padding(.top, 10)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }
}

/// The live strip up to now and the speaker line, redrawn when the voices
/// refresh (at most once a second), never per microphone sample.
private struct MenuBarLiveVoices: View {
    let model: RecordingLiveVoicesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            RecordingNowStrip(strip: model.stage.strip(cast: model.cast), size: .axis)
                .accessibilityIdentifier("menu-bar-live-strip")
            LiveSpeakerLineView(model: model)
        }
    }
}

/// The speaker line under the menu bar's live strip.
private struct LiveSpeakerLineView: View {
    let model: RecordingLiveVoicesModel

    var body: some View {
        if let line = LiveSpeakerLine(stage: model.stage, cast: model.cast) {
            HStack(spacing: 7) {
                LiveSpeakerGlyph(row: line.lead)
                Text(line.styled)
                    .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let voices = line.voices {
                    Text(voices)
                        .monospacedDigit()
                        .foregroundStyle(.ink3)
                        .fixedSize()
                }
            }
            .font(.system(size: 12.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([line.spoken, line.voices].compactMap(\.self).joined(separator: ", "))
            .accessibilityIdentifier("menu-bar-speaker")
        }
    }
}

private struct MenuBarCaption: View {
    let text: String

    var body: some View {
        PVCardCaption(text: text, tint: PVDesign.ink3)
            .padding(.horizontal, 6)
            .padding(.top, 11)
            .padding(.bottom, 4)
    }
}

private struct MenuBarDivider: View {
    var body: some View {
        Rectangle()
            .fill(PVDesign.line)
            .frame(height: 1)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }
}

/// A menu-like row: full width, 28 pt, highlighted under the pointer.
private struct MenuBarRow<Label: View>: View {
    let identifier: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 13))
                .foregroundStyle(PVDesign.ink)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.horizontal, 10)
                .background(
                    hovering ? PVDesign.line : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier(identifier)
    }
}

enum MenuBarFormat {
    /// "in 15 min", "tomorrow".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        formatter.locale = AppLanguage.current.locale
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "10:00 AM · Marta, Nora".
    static func eventDetail(_ event: UpcomingEvent) -> String {
        let time = event.startDate.formatted(.dateTime.hour().minute().locale(AppLanguage.current.locale))
        let people = VoicesTableFormat.summary(event.attendees)
        return people.isEmpty ? time : "\(time) · \(people)"
    }

    /// The clock time for today, the day before that.
    static func started(_ date: Date, calendar: Calendar = .current) -> String {
        let locale = AppLanguage.current.locale
        return calendar.isDateInToday(date)
            ? date.formatted(.dateTime.hour().minute().locale(locale))
            : date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
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
            .font(.system(size: 13))
            .accessibilityIdentifier("menu-bar-launch-at-login")
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
