import IntegrationsKit
import PortavozCore
import SwiftUI

enum Route: Hashable {
    /// nil = blank recording; an event links the recording to the calendar
    /// meeting it came from (real title instead of the timestamp template).
    case recording(UpcomingEvent?)
    case meeting(MeetingID)
    case ask
}

struct ContentView: View {
    @Environment(AppServices.self) private var services
    @State private var route: Route?
    @State private var reminder = MeetingReminderController()
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            LibraryView(route: $route)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            switch route {
            case .recording(let event):
                RecordingView(route: $route, event: event)
            case .meeting(let id):
                MeetingDetailView(meetingID: id, route: $route)
                    .id(id)  // reload state when switching meetings
            case .ask:
                AskView(route: $route)
            case nil:
                ContentUnavailableView(
                    "Portavoz",
                    systemImage: "waveform.badge.mic",
                    // One-line UI copy.
                    // swiftlint:disable:next line_length
                    description: Text("Record a meeting or choose one from the library. Everything is processed on your Mac.")
                )
            }
        }
        .task { await services.seedDemoIfRequested() }
        .task { await services.seedShowcaseIfRequested() }
        .task { reminder.start(services: services) }
        .task {
            // T4 startup bench (hidden launch arg): measures to first frame,
            // so it must live in the view; it exits the process when done.
            BenchMode.reportStartupIfRequested()
        }
        .task { await decideOnboarding() }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
                .portavozLocalized()
                .environment(services)
                .tint(.indigo)
        }
        .onChange(of: services.pendingRoute) { _, pending in
            if let pending {
                route = pending
                services.pendingRoute = nil
            }
        }
    }

    /// First-run setup shows once (GAPS #6). `-show-onboarding` forces it
    /// (dev/UITest); `-use-temp-store` suppresses it so the coordinate-based
    /// UI tests never race a surprise sheet; a library that already has
    /// meetings marks itself onboarded — that user needs no welcome tour.
    private func decideOnboarding() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-show-onboarding") {
            showOnboarding = true
            return
        }
        guard !arguments.contains("-use-temp-store"),
            !UserDefaults.standard.bool(forKey: "hasOnboarded")
        else { return }
        if let meetings = try? await services.store.meetings(), !meetings.isEmpty {
            UserDefaults.standard.set(true, forKey: "hasOnboarded")
            return
        }
        showOnboarding = true
    }
}
