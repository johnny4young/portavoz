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
        .task { reminder.start(services: services) }
        .onChange(of: services.pendingRoute) { _, pending in
            if let pending {
                route = pending
                services.pendingRoute = nil
            }
        }
    }
}
