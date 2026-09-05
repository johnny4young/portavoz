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
    /// Moves every meeting directory to a new root.
    ///
    /// `skipping` names directories that must be left where they are because
    /// something still holds their files open. The cross-volume branch below
    /// copies and then deletes the source, so migrating a directory whose
    /// writers are live unlinks it underneath them and silently truncates the
    /// recording. Callers pass the live meetings; this is the last line of
    /// defence behind `ManageRecordingStorage`'s activity gate.
    public func migrateAudio(
        from origin: URL,
        to destination: URL,
        skipping reservedDirectoryNames: Set<String> = [],
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

        var movedNames: [String] = []
        for (index, entry) in entries.enumerated() {
            progress?(index + 1, entries.count)
            guard !reservedDirectoryNames.contains(entry.lastPathComponent) else {
                continue
            }
            let target = targetAudio.appendingPathComponent(entry.lastPathComponent)
            if manager.fileExists(atPath: target.path) {
                // Already migrated on a previous, interrupted run. Meeting
                // dirs are immutable UUID-named recordings: same name IS the
                // same content, so finish the move by dropping the source.
                try? manager.removeItem(at: entry)
                movedNames.append(entry.lastPathComponent)
                continue
            }
            do {
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
            } catch {
                // The caller only persists the new root after this returns, so
                // a throw here would leave the root pointing at `origin` while
                // some recordings already sit under `destination` — reachable
                // from neither root, since `resolve` only ever looks at the
                // current and default roots. Put back what this run moved so a
                // failure really does mean nothing happened.
                throw restore(
                    movedNames,
                    failing: entry.lastPathComponent,
                    from: targetAudio,
                    to: sourceAudio,
                    after: error,
                    using: manager)
            }
            movedNames.append(entry.lastPathComponent)
        }
        return movedNames.count
    }

    /// Returns the error to throw: the original cause when every directory made
    /// it back, or a stranding report naming what did not.
    ///
    /// `failing` is the entry that threw. Its hidden cross-volume temp may hold
    /// a complete copy of that meeting's audio, and leaving it behind would
    /// contradict "nothing happened" — a later resume would find it and could
    /// not tell it from a finished directory.
    private func restore(
        _ names: [String],
        failing: String?,
        from targetAudio: URL,
        to sourceAudio: URL,
        after cause: Error,
        using manager: FileManager
    ) -> Error {
        if let failing {
            try? manager.removeItem(at: targetAudio.appendingPathComponent(
                ".partial-" + failing))
        }
        var stranded: [String] = []
        for name in names {
            let target = targetAudio.appendingPathComponent(name)
            let source = sourceAudio.appendingPathComponent(name)
            guard manager.fileExists(atPath: target.path) else { continue }
            do {
                try putBack(
                    target,
                    over: source,
                    named: name,
                    in: sourceAudio,
                    using: manager)
            } catch {
                stranded.append(name)
            }
        }
        guard stranded.isEmpty else {
            return RecordingsMigrationError.stranded(
                count: stranded.count,
                at: targetAudio,
                cause: cause)
        }
        return cause
    }

    /// Moves one directory back over whatever is at its origin, and either
    /// succeeds completely or leaves the origin exactly as it found it.
    ///
    /// Deliberately not `replaceItemAt`, which fails this job twice. It cannot
    /// cross volumes at all (EXDEV) — and crossing volumes is the only reason
    /// the migration has a copy path — so on an external drive it would strand
    /// every directory it was supposed to restore. Worse, on one volume it can
    /// throw *after* it has already swapped: the good copy lands correctly, but
    /// the old contents are left at the destination's real name and the caller
    /// is told the entry was stranded. A later resume then finds that name,
    /// treats it as a finished migration, and drops the restored source —
    /// destroying the audio.
    ///
    /// A rename inside one directory needs no permission to delete children, so
    /// quarantining the existing origin works even when removing it does not.
    private func putBack(
        _ target: URL,
        over source: URL,
        named name: String,
        in sourceAudio: URL,
        using manager: FileManager
    ) throws {
        guard manager.fileExists(atPath: source.path) else {
            try manager.moveItem(at: target, to: source)
            return
        }
        // Hidden and inside the *source* folder, never at the destination's
        // real name. `contentsOfDirectory` skips hidden entries, so a leftover
        // can never be mistaken for a meeting directory by a later migration.
        let quarantine = sourceAudio.appendingPathComponent(".superseded-" + name)
        try? manager.removeItem(at: quarantine)
        try manager.moveItem(at: source, to: quarantine)
        do {
            try manager.moveItem(at: target, to: source)
        } catch {
            // Put the origin back so a failed restore leaves it no worse.
            try? manager.moveItem(at: quarantine, to: source)
            throw error
        }
        try? manager.removeItem(at: quarantine)
    }
}

/// A migration that could neither finish nor fully undo itself.
public enum RecordingsMigrationError: LocalizedError {
    /// Recordings that reached the destination but could not be put back. The
    /// count and folder are enough for the user to find them; naming the
    /// meetings would put library content into an error message.
    case stranded(count: Int, at: URL, cause: Error)

    /// Spelled out here rather than left to the default `Error` description,
    /// which renders as an opaque "operation couldn't be completed" and would
    /// drop the only two facts the user needs.
    public var errorDescription: String? {
        switch self {
        case .stranded(let count, let at, let cause):
            return """
                \(count) recording(s) were moved to \(at.path) and could not be \
                put back (\(cause.localizedDescription)). They are safe there; \
                move them back into the Audio folder of your recordings \
                location, or point Portavoz at that folder.
                """
        }
    }
}
