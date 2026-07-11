import Foundation

/// M16: runs the user's chosen Shortcut when a meeting ends, feeding it
/// the meeting's Markdown export as input — "when a meeting ends, send
/// the summary to Notes/mail/Slack" without touching the app. Best-effort
/// by design: the Shortcut belongs to the user and its failures surface
/// in Shortcuts itself, not here; the meeting is already saved either way.
enum PostMeetingShortcut {
    static let defaultsKey = "postMeetingShortcutName"

    /// Fire-and-forget: never blocks the post-meeting pipeline.
    static func runIfConfigured(markdown: String) {
        let name = (UserDefaults.standard.string(forKey: defaultsKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-meeting-\(UUID().uuidString).md")
        do {
            try Data(markdown.utf8).write(to: input)
        } catch {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name, "--input-path", input.path]
        process.terminationHandler = { _ in
            try? FileManager.default.removeItem(at: input)
        }
        try? process.run()
    }
}
