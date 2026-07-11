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
                // swiftlint:disable:next line_length
                "Type the exact name of a Shortcut; it receives the finished meeting as Markdown (summary, action items and transcript) — connect it to Notes, Mail, Slack or anything else. Tip: any automation tool can also start a recording by opening portavoz://record."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
