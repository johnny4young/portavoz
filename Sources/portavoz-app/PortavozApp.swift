import SwiftUI

/// The macOS shell (M5). All heavy lifting lives in the Kits; the app is
/// glue: library browsing, live recording, and the post-meeting pipeline.
@main
struct PortavozApp: App {
    @State private var services = AppServices()

    init() {
        let process = ProcessInfo.processInfo
        if process.arguments.contains("-reset-app-language")
            || process.environment["PORTAVOZ_RESET_APP_LANGUAGE"] == "1" {
            UserDefaults.standard.removeObject(forKey: AppLanguage.storageKey)
        }

        // Hidden bench mode (M12): "--bench-live <file>" runs the
        // SpeechAnalyzer harness inside the bundle and exits.
        BenchMode.runIfRequested()
        BenchMode.runMLXSmokeIfRequested()
        // Driven from init, not a view .task: a headless launch (open -n
        // from a script) may never mount the window, and the T4 RAM bench
        // must still run.
        BenchMode.runRecordBenchIfRequested(services: services, recording: RecordingController())
        // Global feature, not a window feature: ⌥⌘D must work even with
        // the library window closed.
        services.dictation.syncHotkey(services: services)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .portavozLocalized()
                .environment(services)
                .frame(minWidth: 900, minHeight: 560)
                .tint(.indigo)
                .modifier(OpenSettingsSheetModifier(services: services))
        }
        .commands {
            CheckForUpdatesCommand()
        }
        Settings {
            SettingsView()
                .portavozLocalized()
                .environment(services)
                .tint(.indigo)
        }
    }
}

private struct OpenSettingsSheetModifier: ViewModifier {
    let services: AppServices
    @State private var showSettings = false

    func body(content: Content) -> some View {
        content
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-portavoz-open-settings"),
                      !showSettings else { return }
                try? await Task.sleep(for: .milliseconds(1500))
                showSettings = true
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .portavozLocalized()
                    .environment(services)
                    .tint(.indigo)
            }
    }
}
