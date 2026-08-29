import AppKit
import CoreSpotlight
import PortavozCore
import SwiftUI

enum Route: Hashable {
    case library
    /// nil = blank recording; an event links the recording to the calendar
    /// meeting it came from (real title instead of the timestamp template).
    case recording(UpcomingEvent?)
    /// Reveals an existing typed recording failure without starting capture.
    case recordingRecovery
    case meeting(MeetingID)
    case ask
    case insights
    case commitments(CommitmentRadarRouteFocus?)
}

extension Route {
    var isCommitmentRadar: Bool {
        guard case .commitments = self else { return false }
        return true
    }
}

enum CommitmentRadarRouteFocus: Hashable {
    case person(PersonID)
    case commitment(CommitmentID)
}

struct ContentView: View {
    let services: AppServices
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var route: Route?
    @State private var libraryModel: LibraryModel
    @State private var insightsModel: InsightsModel
    @State private var askModel: AskModel
    @State private var commitmentRadarModel: CommitmentRadarModel
    @State private var reminderDraftModel: ReminderDraftModel
    @State private var reminder = MeetingReminderController()
    @State private var firstRunHostID = UUID()

    init(services: AppServices) {
        self.services = services
        _libraryModel = State(initialValue: services.makeLibraryModel())
        _insightsModel = State(initialValue: services.makeInsightsModel())
        _askModel = State(initialValue: services.makeAskModel())
        _commitmentRadarModel = State(
            initialValue: services.makeCommitmentRadarModel())
        _reminderDraftModel = State(
            initialValue: services.makeReminderDraftModel())
    }

    var body: some View {
        NavigationSplitView {
            LibraryView(
                model: libraryModel,
                route: $route,
                recordingActive: services.recording.canReturnToLiveSession,
                onReturnToRecording: {
                    route = .recording(nil)
                },
                onOpenSearchHit: { hit in
                    services.requestMeetingSeek(
                        meetingID: hit.meetingID,
                        timestamp: hit.startTime)
                    route = .meeting(hit.meetingID)
                })
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
                .background { AuroraSidebarBackground() }
        } detail: {
            Group {
                switch route {
                case .recording(let event):
                    RecordingView(
                        route: $route,
                        event: event,
                        startsAutomatically: true)
                case .recordingRecovery:
                    RecordingView(
                        route: $route,
                        event: nil,
                        startsAutomatically: false)
                case .meeting(let id):
                    MeetingDetailScene(
                        services: services,
                        meetingID: id,
                        route: $route)
                        .id(id)  // Reset route-owned state when switching meetings.
                case .ask:
                    AskView(
                        model: askModel,
                        onOpenCitation: { citation in
                            services.requestMeetingSeek(for: citation)
                            route = .meeting(citation.meetingID)
                        },
                        onOpenNoteCitation: { citation in
                            services.requestMeetingSeek(
                                meetingID: citation.meetingID,
                                timestamp: citation.timestamp)
                            route = .meeting(citation.meetingID)
                        })
                case .insights:
                    InsightsView(model: insightsModel, route: $route)
                case .commitments(let focus):
                    CommitmentRadarView(
                        model: commitmentRadarModel,
                        reminders: services.commitmentReminders,
                        reminderDrafts: reminderDraftModel,
                        focus: focus,
                        onClearFocus: { route = .commitments(nil) },
                        onOpenMeeting: { meetingID, timestamp in
                            if let timestamp {
                                services.requestMeetingSeek(
                                    meetingID: meetingID,
                                    timestamp: timestamp)
                            }
                            route = .meeting(meetingID)
                        })
                case .library, nil:
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
        .toolbar {
            ToolbarItem(placement: .automatic) {
                BackgroundWorkIndicator(
                    model: services.backgroundWork,
                    openCenter: {
                        services.pendingSettingsCategory = .backgroundWork
                        openSettings()
                    })
            }
        }
        .task {
            // The value-scoped main WindowGroup reuses its primary window
            // instead of creating a duplicate when a citation brings it back.
            services.palette.openMainWindow = {
                openWindow(id: "main", value: MainWindowIdentity.primary)
                NSApp.activate(ignoringOtherApps: true)
            }
            services.palette.onOpenCitation = { citation in
                services.requestMeetingSeek(for: citation)
                services.pendingRoute = .meeting(citation.meetingID)
            }
        }
        .task {
            await services.seedDemoIfRequested()
            await services.routeAutomationEntityIfRequested()
        }
        .task { await services.seedScaleBenchmarkIfRequested() }
        .task { positionUITestWindowIfNeeded() }
        .task { await services.purgeExpiredTrash() }
        .task { await services.seedShowcaseIfRequested() }
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
        .onAppear { services.firstRun.register(hostID: firstRunHostID) }
        .task { await services.firstRun.resolve(in: firstRunHostID) }
        .onDisappear { services.firstRun.unregister(hostID: firstRunHostID) }
        .sheet(isPresented: Binding(
            get: { services.firstRun.isPresented(in: firstRunHostID) },
            set: { services.firstRun.setPresented($0, in: firstRunHostID) }
        )) {
            OnboardingView(onFinish: services.firstRun.finish)
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

    /// Keep the throwaway XCUITest window clear of persistent desktop
    /// overlays (for example, an agent progress panel) and on AppKit's zero
    /// screen. This is deliberately scoped to `-use-temp-store`: production
    /// window placement remains owned by SwiftUI and the user's saved macOS
    /// window state.
    @MainActor
    private func positionUITestWindowIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-use-temp-store"),
              let window = NSApp.windows.first(where: {
                  !($0 is NSPanel) && $0.canBecomeMain
              })
        else { return }
        UITestWindowPlacement.positionMainWindow(window)
    }
}
