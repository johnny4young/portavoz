import SwiftUI

/// The macOS shell (M5). All heavy lifting lives in the Kits; the app is
/// glue: library browsing, live recording, and the post-meeting pipeline.
@main
struct PortavozApp: App {
    @NSApplicationDelegateAdaptor(PortavozAppDelegate.self) private var appDelegate
    @State private var services = AppServices()

    init() {
        PortavozAppDelegate.services = services
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
        BenchMode.runRecordBenchIfRequested(services: services, recording: services.recording)
        // Recovery belongs to process launch, not a window: interrupted audio
        // and expired leases are reconciled even when only the menu bar opens.
        let appServices = services
        Task { @MainActor in
            await appServices.meetingSync.start()
        }
        Task { @MainActor in
            await RecordingRecoveryCoordinator.runIfNeeded(services: appServices)
            await PostCaptureProcessingCoordinator.resumeAfterRecovery(
                services: appServices)
            // Optional local-provider discovery must never delay recovery of
            // finalized audio or resumption of its durable transcript work.
            await appServices.configureInitialSummaryEngineIfNeeded()
        }
        // Global feature, not a window feature: ⌥⌘D must work even with
        // the library window closed.
        services.dictation.syncHotkey(services: services)
    }

    @AppStorage("menuBarEnabled") private var menuBarEnabled = true

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(services: services)
                .portavozLocalized()
                .environment(services)
                .frame(minWidth: 900, minHeight: 560)
                .tint(PVDesign.accent)
        }
        .commands {
            CheckForUpdatesCommand()
            CommandGroup(after: .newItem) {
                Button("Ask your week…") {
                    services.palette.toggle(services: services)
                }
                .keyboardShortcut("k")
            }
        }
        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarContent(model: services.makeMenuBarModel())
                .portavozLocalized()
                .environment(services)
                .tint(PVDesign.accent)
        } label: {
            // «La P que habla» as a template image at rest; the red dot
            // while a meeting records — the glanceable "am I recording?"
            // answer. (The DS's pulsing-stem idea stays a web flourish.)
            if services.recording.phase == .recording {
                Image(systemName: "record.circle.fill")
            } else if let icon = MenuBarIcon.image {
                Image(nsImage: icon)
            } else {
                Image(systemName: "waveform.and.mic")
            }
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView()
                .portavozLocalized()
                .environment(services)
                .tint(PVDesign.accent)
        }
    }
}
