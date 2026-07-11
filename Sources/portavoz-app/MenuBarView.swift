import ServiceManagement
import SwiftUI

/// The resident menu-bar presence: recording state at a glance, one-click
/// start/stop, dictation, and launch-at-login — Portavoz keeps working
/// with the library window closed (the hotkey and this menu both live in
/// the App, not the window).
struct MenuBarContent: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if services.recording.phase == .recording {
                Button {
                    let services = self.services
                    Task { await services.recording.stop(services: services) }
                } label: {
                    Label("Stop recording", systemImage: "stop.circle")
                }
            } else {
                Button {
                    openMainWindow()
                    services.pendingRoute = .recording(nil)
                } label: {
                    Label("Start recording", systemImage: "record.circle")
                }
            }
            if UserDefaults.standard.bool(forKey: DictationController.defaultsKey) {
                Button {
                    services.dictation.toggle(services: services)
                } label: {
                    Label("Dictate (⌥⌘D)", systemImage: "waveform.badge.mic")
                }
            }
            Divider()
            Button {
                openMainWindow()
            } label: {
                Label("Open Portavoz", systemImage: "rectangle.stack")
            }
            LaunchAtLoginToggle()
            Divider()
            Button("Quit Portavoz") {
                NSApp.terminate(nil)
            }
        }
    }

    private func openMainWindow() {
        // Re-open the library window if the user closed it, then front it.
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// `SMAppService.mainApp` wants the app in /Applications (it is — that's
/// the install story). State is re-read on every menu open; registration
/// errors surface by the toggle simply not flipping.
private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: $enabled)
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
