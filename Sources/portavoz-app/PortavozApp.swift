import SwiftUI

/// The macOS shell (M5). All heavy lifting lives in the Kits; the app is
/// glue: library browsing, live recording, and the post-meeting pipeline.
@main
struct PortavozApp: App {
    @NSApplicationDelegateAdaptor(PortavozAppDelegate.self) private var appDelegate
    @State private var launch: AppLaunchModel
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true

    init() {
        let process = ProcessInfo.processInfo
        BenchResourceLaunchProbe.runIfRequested(arguments: process.arguments)
        if process.arguments.contains("-reset-app-language")
            || process.environment["PORTAVOZ_RESET_APP_LANGUAGE"] == "1" {
            UserDefaults.standard.removeObject(forKey: AppLanguage.storageKey)
        }
        if process.arguments.contains("-use-temp-store")
            && process.arguments.contains("-simulate-app-intent") {
            // XCUITest-only proof of the native intent's cold-launch race:
            // queue the request before applicationDidFinishLaunching installs
            // the delegate observer, then require the buffer to deliver it.
            PortavozAppIntentBridge.requestStartRecording()
        }

        // These two hidden modes do not require the application database.
        BenchMode.runIfRequested()
        BenchMode.runMLXSmokeIfRequested()

        let launch = AppLaunchModel(
            arguments: process.arguments,
            environment: process.environment)
        _launch = State(initialValue: launch)
        launch.activateReadyServicesIfNeeded()
    }

    var body: some Scene {
        WindowGroup(
            id: "main",
            for: MainWindowIdentity.self
        ) { _ in
            AppLaunchRootView(model: launch)
                .portavozLocalized()
                .frame(minWidth: 900, minHeight: 560)
                .tint(PVDesign.accent)
        } defaultValue: {
            .primary
        }
        .commands {
            CheckForUpdatesCommand()
            if let services = launch.services {
                CommandGroup(after: .newItem) {
                    Button("Ask your week…") {
                        services.palette.toggle()
                    }
                    .keyboardShortcut("k")
                }
            }
        }
        MenuBarExtra(isInserted: $menuBarEnabled) {
            AppLaunchMenuBarContent(model: launch)
                .portavozLocalized()
                .tint(PVDesign.accent)
        } label: {
            if launch.services?.recording.phase == .recording {
                Image(systemName: "record.circle.fill")
            } else if let icon = MenuBarIcon.image {
                Image(nsImage: icon)
            } else {
                Image(systemName: "waveform.and.mic")
            }
        }
        .menuBarExtraStyle(.window)
        Settings {
            AppLaunchSettingsRoot(model: launch)
                .portavozLocalized()
                .tint(PVDesign.accent)
        }
    }
}

private struct AppLaunchRootView: View {
    let model: AppLaunchModel

    var body: some View {
        switch model.phase {
        case .opening:
            AppLaunchOpeningView()
        case let .ready(services):
            if presentsMenuBarUITestFixture {
                MenuBarContent(model: services.makeMenuBarModel())
                    .environment(services)
                    .task { await services.seedDemoIfRequested() }
            } else {
                ContentView(services: services)
                    .environment(services)
            }
        case .databaseUnavailable:
            AppLaunchRecoveryView(model: model)
        }
    }

    /// XCUITest cannot deterministically open a MenuBarExtra window across
    /// macOS versions. Mount the exact production content/model in the
    /// disposable main test window; neither flag alone can affect production.
    private var presentsMenuBarUITestFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-use-temp-store")
            && arguments.contains("-show-menu-bar-content")
    }
}

private struct AppLaunchSettingsRoot: View {
    let model: AppLaunchModel

    var body: some View {
        switch model.phase {
        case .opening:
            AppLaunchOpeningView()
                .frame(minWidth: 560, minHeight: 360)
        case let .ready(services):
            SettingsView()
                .environment(services)
        case .databaseUnavailable:
            AppLaunchRecoveryView(model: model)
                .frame(minWidth: 760, minHeight: 500)
        }
    }
}

private struct AppLaunchMenuBarContent: View {
    let model: AppLaunchModel

    var body: some View {
        switch model.phase {
        case .opening:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Opening your library…")
            }
            .padding()
        case let .ready(services):
            MenuBarContent(model: services.makeMenuBarModel())
                .environment(services)
        case .databaseUnavailable:
            Label(
                "Library unavailable — open Portavoz to recover",
                systemImage: "externaldrive.badge.exclamationmark")
                .padding()
        }
    }
}
