import SwiftUI

/// Settings section for M16 automations: the post-meeting Shortcut hook
/// and the `portavoz://record` URL scheme for external triggers.
struct AutomationSection: View {
    @AppStorage(PostMeetingShortcut.defaultsKey) private var shortcutName = ""

    var body: some View {
        Section("Automation") {
            TextField("Run a Shortcut when a meeting ends", text: $shortcutName)
                .accessibilityIdentifier("settings-automation-shortcut")
            Text(
                // One-line UI help text.
                "Type a Shortcut name. It receives the finished meeting as Markdown. Any tool can also open portavoz://record."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Menu-bar presence toggle: the `MenuBarExtra` scene observes the same
/// key via `isInserted`, so the icon appears/disappears immediately.
struct MenuBarSection: View {
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true

    var body: some View {
        Section("Menu bar") {
            Toggle("Show Portavoz in the menu bar", isOn: $menuBarEnabled)
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Recording state at a glance, one-click start/stop and dictation — Portavoz keeps working with the window closed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
