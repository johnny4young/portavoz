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
            let manager = FileManager.default
            do {
                let attributes = try manager.attributesOfItem(atPath: markerURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try manager.removeItem(at: markerURL)
            } catch let error as CocoaError
                where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                // Resetting an already-default location is idempotent.
            }
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

    /// Moves audio and publishes the selected root as one recoverable operation.
    /// A marker-write/reset failure rolls back only directories moved by this run.
    @discardableResult
    public func migrateRoot(
        to destination: URL?,
        skipping reservedDirectoryNames: Set<String> = [],
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> Int {
        guard reservedDirectoryNames.isEmpty else {
            throw RecordingsMigrationError.recordingsInUse
        }
        return try performMigration(
            from: currentRoot(),
            to: destination ?? defaultRoot,
            commitRoot: { try setRoot(destination) },
            progress: progress)
    }

    /// Moves audio without changing the marker. Existing destinations are only
    /// adopted when their complete directory trees and file bytes match exactly.
    /// Live writer directories must be reserved by the caller.
    @discardableResult
    public func migrateAudio(
        from origin: URL,
        to destination: URL,
        skipping reservedDirectoryNames: Set<String> = [],
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> Int {
        try performMigration(
            from: origin, to: destination, skipping: reservedDirectoryNames,
            commitRoot: {}, progress: progress)
    }

    /// Internal commit seam exercises marker failures without relying on host
    /// permissions. Production always supplies `setRoot` from `migrateRoot`.
    func performMigration(
        from origin: URL,
        to destination: URL,
        skipping reservedDirectoryNames: Set<String> = [],
        commitRoot: () throws -> Void,
        removeSource: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> Int {
        let manager = FileManager.default
        let sourceAudio = origin.appendingPathComponent("Audio", isDirectory: true)
        let targetAudio = destination.appendingPathComponent("Audio", isDirectory: true)
        guard try prepareMigration(from: sourceAudio, to: targetAudio, using: manager) else {
            try commitRoot()
            return 0
        }
        let entries = try manager.contentsOfDirectory(
            at: sourceAudio, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var movedNames: [String] = []
        var duplicates: [URL] = []
        do {
            for (index, entry) in entries.enumerated() {
                progress?(index + 1, entries.count)
                guard !reservedDirectoryNames.contains(entry.lastPathComponent) else { continue }
                let target = targetAudio.appendingPathComponent(entry.lastPathComponent)
                if (try? manager.attributesOfItem(atPath: target.path)) != nil {
                    guard try identicalRecording(entry, target, using: manager) else {
                        throw RecordingsMigrationError.conflictingDestination(at: targetAudio)
                    }
                    // A pre-existing copy is not ours to move or clean up.
                    // Keep both originals through success and failure.
                    duplicates.append(entry)
                } else {
                    try moveRecording(entry, to: target, movedNames: &movedNames,
                                      using: manager, removeSource: removeSource)
                }
            }
            for entry in duplicates {
                let target = targetAudio.appendingPathComponent(entry.lastPathComponent)
                guard try identicalRecording(entry, target, using: manager) else {
                    throw RecordingsMigrationError.conflictingDestination(at: targetAudio)
                }
            }
            try commitRoot()
        } catch {
            throw restore(movedNames, from: targetAudio,
                          to: sourceAudio, after: error, using: manager)
        }
        // A pre-existing destination is not owned by this transaction. Keep
        // its original even after commit: matching bytes do not fence later
        // external changes to either copy.
        return movedNames.count + duplicates.count
    }

    private func prepareMigration(
        from sourceAudio: URL,
        to targetAudio: URL,
        using manager: FileManager
    ) throws -> Bool {
        let source = sourceAudio.standardizedFileURL.resolvingSymlinksInPath()
        let target = targetAudio.standardizedFileURL.resolvingSymlinksInPath()
        guard source != target else { return false }
        guard !target.path.hasPrefix(source.path + "/"),
              !source.path.hasPrefix(target.path + "/") else {
            throw RecordingsMigrationError.conflictingDestination(at: targetAudio)
        }
        // An empty selected root must exist before its marker is authoritative.
        try manager.createDirectory(at: targetAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard manager.fileExists(atPath: sourceAudio.path) else { return false }
        try manager.createDirectory(at: targetAudio, withIntermediateDirectories: true)
        return true
    }

    private func moveRecording(
        _ entry: URL,
        to target: URL,
        movedNames: inout [String],
        using manager: FileManager,
        removeSource: (URL) throws -> Void
    ) throws {
        // FileManager.moveItem can copy/delete across volumes and throw after
        // publication. Own those phases explicitly, including on one volume.
        let temp = target.deletingLastPathComponent().appendingPathComponent(
            ".partial-" + entry.lastPathComponent + "-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temp) }
        try manager.copyItem(at: entry, to: temp)
        try manager.moveItem(at: temp, to: target)
        movedNames.append(entry.lastPathComponent)
        try removeSource(entry)
    }

    /// Do not follow symlinks or equate a file with a recording directory.
    /// Include hidden children and compare file contents without loading whole
    /// recordings into memory. The activity gate excludes active writers.
    private func identicalRecording(_ source: URL, _ target: URL, using manager: FileManager) throws -> Bool {
        let sourceType = try manager.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType
        let targetType = try manager.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType
        guard sourceType == .typeDirectory, targetType == .typeDirectory else { return false }
        let sourceNames = try manager.contentsOfDirectory(atPath: source.path).sorted()
        let targetNames = try manager.contentsOfDirectory(atPath: target.path).sorted()
        guard sourceNames == targetNames else { return false }
        for name in sourceNames {
            let left = source.appendingPathComponent(name)
            let right = target.appendingPathComponent(name)
            let leftType = try manager.attributesOfItem(atPath: left.path)[.type] as? FileAttributeType
            let rightType = try manager.attributesOfItem(atPath: right.path)[.type] as? FileAttributeType
            guard leftType == rightType else { return false }
            switch leftType {
            case .typeDirectory:
                guard try identicalRecording(left, right, using: manager) else { return false }
            case .typeRegular:
                guard manager.contentsEqual(atPath: left.path, andPath: right.path) else { return false }
            default:
                return false
            }
        }
        return true
    }

    /// Returns the error to throw: the original cause when every directory made
    /// it back, or a stranding report naming what did not.
    private func restore(
        _ names: [String],
        from targetAudio: URL,
        to sourceAudio: URL,
        after cause: Error,
        using manager: FileManager
    ) -> Error {
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

    /// Restore through a source-volume staging copy. Never overwrite or delete
    /// an origin recreated by another writer: retain it under a unique recovery
    /// name even when publication succeeds. Destination cleanup is best-effort
    /// only after the full recording is available again at the original path.
    private func putBack(
        _ target: URL,
        over source: URL,
        named name: String,
        in sourceAudio: URL,
        using manager: FileManager
    ) throws {
        let suffix = name + "-" + UUID().uuidString
        let temp = sourceAudio.appendingPathComponent(".restore-" + suffix)
        let quarantine = sourceAudio.appendingPathComponent(".superseded-" + suffix)
        defer { try? manager.removeItem(at: temp) }
        try manager.copyItem(at: target, to: temp)
        let hadSource = (try? manager.attributesOfItem(atPath: source.path)) != nil
        if hadSource { try manager.moveItem(at: source, to: quarantine) }
        do {
            try manager.moveItem(at: temp, to: source)
        } catch {
            if hadSource { try? manager.moveItem(at: quarantine, to: source) }
            throw error
        }
        try? manager.removeItem(at: target)
    }
}

/// A migration that could neither finish nor fully undo itself.
public enum RecordingsMigrationError: LocalizedError {
    case recordingsInUse

    /// A same-name destination is not proof of a completed copy.
    case conflictingDestination(at: URL)

    /// Recordings that reached the destination but could not be put back. The
    /// count and folder are enough for the user to find them; naming the
    /// meetings would put library content into an error message.
    case stranded(count: Int, at: URL, cause: Error)

    /// Spelled out here rather than left to the default `Error` description,
    /// which renders as an opaque "operation couldn't be completed" and would
    /// drop the only two facts the user needs.
    public var errorDescription: String? {
        switch self {
        case .recordingsInUse:
            return "Recordings are still in use. Wait for recording to finish before changing the folder."
        case .conflictingDestination(let at):
            return "A recording already exists with different or unverifiable contents in \(at.path). "
                + "Both copies were preserved. Choose another folder or reconcile the copies before retrying."
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
