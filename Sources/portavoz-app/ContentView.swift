import PortavozCore
import SwiftUI

enum Route: Hashable {
    case recording
    case meeting(MeetingID)
}

struct ContentView: View {
    @Environment(AppServices.self) private var services
    @State private var route: Route?

    var body: some View {
        NavigationSplitView {
            LibraryView(route: $route)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            switch route {
            case .recording:
                RecordingView(route: $route)
            case .meeting(let id):
                MeetingDetailView(meetingID: id, route: $route)
                    .id(id)  // reload state when switching meetings
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
    }
}
