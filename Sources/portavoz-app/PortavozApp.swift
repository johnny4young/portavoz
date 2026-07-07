import SwiftUI

/// The macOS shell (M5). All heavy lifting lives in the Kits; the app is
/// glue: library browsing, live recording, and the post-meeting pipeline.
@main
struct PortavozApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(services)
                .frame(minWidth: 900, minHeight: 560)
                .tint(.indigo)
        }
        Settings {
            SettingsView()
                .environment(services)
                .tint(.indigo)
        }
    }
}
