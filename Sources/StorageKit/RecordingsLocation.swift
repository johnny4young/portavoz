import Foundation

/// Where meeting audio lives. The database only ever stores paths RELATIVE
/// to this root (contract D4), so moving the root never touches a row.
///
/// The chosen folder persists as a plain absolute path in a marker file
/// next to the database — a file, not UserDefaults, so the CLI honors the
/// same setting as the app. No security-scoped bookmark: the app runs with
/// hardened runtime but WITHOUT the sandbox, so a plain path keeps working
/// across launches (protected folders like Desktop prompt once via TCC,
/// with the usage strings in Info.plist).
public struct RecordingsLocation: Sendable {
    public let defaultRoot: URL
    public let markerURL: URL

    public init(defaultRoot: URL, markerURL: URL) {
        self.defaultRoot = defaultRoot
        self.markerURL = markerURL
    }

    /// The location shared by app and CLI: the default root is the folder
    /// that holds the database. `PORTAVOZ_AUDIO_ROOT` overrides it — used by
    /// `make test-ui` to point audio at a throwaway folder so a test run
    /// never writes into the real library.
    public static var shared: RecordingsLocation {
        if let override = ProcessInfo.processInfo.environment["PORTAVOZ_AUDIO_ROOT"],
            !override.isEmpty {
            let root = URL(fileURLWithPath: override)
            return RecordingsLocation(
                defaultRoot: root,
                markerURL: root.appendingPathComponent("recordings-root.txt"))
        }
        let support = MeetingStore.defaultDatabaseURL.deletingLastPathComponent()
        return RecordingsLocation(
            defaultRoot: support,
            markerURL: support.appendingPathComponent("recordings-root.txt"))
    }

    /// The active root: the user's chosen folder, or the default. A stale
    /// marker (folder unplugged or deleted) falls back to the default
    /// instead of breaking every new recording.
    public func currentRoot() -> URL {
        guard
            let raw = try? String(contentsOf: markerURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return defaultRoot }
        let url = URL(fileURLWithPath: raw)
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return defaultRoot }
        return url
    }

    public var isCustom: Bool {
        currentRoot().standardizedFileURL != defaultRoot.standardizedFileURL
    }

    /// Persists a new root; nil returns to the default.
    public func setRoot(_ url: URL?) throws {
        guard let url else {
            try? FileManager.default.removeItem(at: markerURL)
            return
        }
        try url.path.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    /// Resolves a database-relative path against the current root, falling
    /// back to the default root — an interrupted migration or an old
    /// meeting that never moved keeps resolving.
    public func resolve(_ relative: String) -> URL {
        let preferred = currentRoot().appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        let fallback = defaultRoot.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: fallback.path) { return fallback }
        return preferred
    }

    /// Moves the `Audio/` tree from `origin` to `destination`, one meeting
    /// directory at a time. Interruption-safe and resumable: a directory
    /// already complete at the destination is skipped (its leftover source
    /// is cleaned up), and when a plain rename can't work (cross-volume)
    /// the copy lands under a hidden temp name and only an atomic rename
    /// publishes it — the source is removed last.
    @discardableResult
    public func migrateAudio(
        from origin: URL,
        to destination: URL,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> Int {
        let canonicalOrigin = origin.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalOrigin != canonicalDestination else {
            return 0
        }
        let manager = FileManager.default
        let sourceAudio = origin.appendingPathComponent("Audio", isDirectory: true)
        let targetAudio = destination.appendingPathComponent("Audio", isDirectory: true)
        guard manager.fileExists(atPath: sourceAudio.path) else { return 0 }
        try manager.createDirectory(at: targetAudio, withIntermediateDirectories: true)

        let entries = try manager.contentsOfDirectory(
            at: sourceAudio, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var moved = 0
        for (index, entry) in entries.enumerated() {
            progress?(index + 1, entries.count)
            let target = targetAudio.appendingPathComponent(entry.lastPathComponent)
            if manager.fileExists(atPath: target.path) {
                // Already migrated on a previous, interrupted run. Meeting
                // dirs are immutable UUID-named recordings: same name IS the
                // same content, so finish the move by dropping the source.
                try? manager.removeItem(at: entry)
                moved += 1
                continue
            }
            do {
                try manager.moveItem(at: entry, to: target)
            } catch {
                let temp = targetAudio.appendingPathComponent(
                    ".partial-" + entry.lastPathComponent)
                try? manager.removeItem(at: temp)
                try manager.copyItem(at: entry, to: temp)
                try manager.moveItem(at: temp, to: target)
                try manager.removeItem(at: entry)
            }
            moved += 1
        }
        return moved
    }
}
