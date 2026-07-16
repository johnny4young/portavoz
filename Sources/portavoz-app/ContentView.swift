import AppKit
import CoreSpotlight
import PortavozCore
import SwiftUI

enum Route: Hashable {
    /// nil = blank recording; an event links the recording to the calendar
    /// meeting it came from (real title instead of the timestamp template).
    case recording(UpcomingEvent?)
    case meeting(MeetingID)
    case ask
    case insights
}

struct ContentView: View {
    let services: AppServices
    @Environment(\.openWindow) private var openWindow
    @State private var route: Route?
    @State private var libraryModel: LibraryModel
    @State private var insightsModel: InsightsModel
    @State private var reminder = MeetingReminderController()
    @State private var showOnboarding = false

    init(services: AppServices) {
        self.services = services
        _libraryModel = State(initialValue: services.makeLibraryModel())
        _insightsModel = State(initialValue: services.makeInsightsModel())
    }

    var body: some View {
        NavigationSplitView {
            LibraryView(
                model: libraryModel,
                route: $route)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
                .background { AuroraSidebarBackground() }
        } detail: {
            Group {
                switch route {
                case .recording(let event):
                    RecordingView(route: $route, event: event)
                case .meeting(let id):
                    MeetingDetailView(
                        services: services,
                        meetingID: id,
                        route: $route)
                        .id(id)  // reload state when switching meetings
                case .ask:
                    AskView(route: $route)
                case .insights:
                    InsightsView(model: insightsModel, route: $route)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { AuroraDetailBackground() }
        }
        .task {
            // Palette citations may need to reopen the library window —
            // but only when none is visible: openWindow ALWAYS creates a
            // new one, and a citation should reuse the window you have.
            services.palette.openMainWindow = {
                let hasMainWindow = NSApp.windows.contains {
                    !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain
                }
                if !hasMainWindow {
                    openWindow(id: "main")
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .task { await services.seedDemoIfRequested() }
        .task { await services.purgeExpiredTrash() }
        .task { await services.seedShowcaseIfRequested() }
        .task(id: services.libraryVersion) {
            // M16: meetings searchable from Spotlight. Full rebuild — cheap
            // (metadata only) and immune to delete drift.
            await SpotlightIndexer.reindexAll(store: services.store)
        }
        .onOpenURL { url in
            // M16: portavoz://record — Shortcuts/automation tools can start
            // a recording (the user still sees it; nothing records hidden).
            if url.host() == "record" {
                route = .recording(nil)
            }
        }
        .task {
            // Cold start: a Spotlight hit can set pendingRoute BEFORE this
            // view mounts, and onChange never fires for the initial value.
            if let pending = services.pendingRoute {
                route = pending
                services.pendingRoute = nil
            }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            // A Spotlight hit: its unique identifier is the meeting UUID.
            guard
                let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                let uuid = UUID(uuidString: raw)
            else { return }
            route = .meeting(MeetingID(rawValue: uuid))
        }
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
                .tint(PVDesign.accent)
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
