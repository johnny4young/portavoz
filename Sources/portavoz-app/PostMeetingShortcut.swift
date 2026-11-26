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
        run(
            shortcutName: name,
            markdown: markdown,
            temporaryDirectory: FileManager.default.temporaryDirectory
        ) { inputURL, onComplete in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name, "--input-path", inputURL.path]
            process.terminationHandler = { _ in onComplete() }
            try process.run()
        }
    }

    static func run(
        shortcutName: String,
        markdown: String,
        temporaryDirectory: URL,
        launch: (_ inputURL: URL, _ onComplete: @escaping @Sendable () -> Void) throws -> Void
    ) {
        guard !shortcutName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let input = temporaryDirectory
            .appendingPathComponent("portavoz-meeting-\(UUID().uuidString).md")
        // Create with owner-only permissions up front so meeting text is never world-readable.
        guard FileManager.default.createFile(
            atPath: input.path,
            contents: Data(markdown.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            return
        }
        let cleanup: @Sendable () -> Void = {
            try? FileManager.default.removeItem(at: input)
        }
        do {
            try launch(input, cleanup)
        } catch {
            cleanup()
        }
    }
}
