import Foundation

/// A finite, disposable-store-only synchronization seam for UI fixtures whose
/// intermediate state must remain observable on both fast and hosted runners.
/// Production composition never supplies these arguments or environment keys.
enum UITestFeatureHandshake {
    struct ConfigurationError: Error {}
    struct SignalCreationError: Error {}
    struct TimedOut: Error {}

    static func pauseIfRequested(
        argument: String,
        readyEnvironmentKey: String,
        continueEnvironmentKey: String,
        attempts: Int = 600
    ) async throws {
        guard ProcessInfo.processInfo.arguments.contains(argument) else {
            return
        }
        guard attempts > 0 else { throw ConfigurationError() }

        let readyPath = try signalPath(for: readyEnvironmentKey)
        let continuePath = try signalPath(for: continueEnvironmentKey)
        guard readyPath != continuePath else { throw ConfigurationError() }
        let fileManager = FileManager.default
        for path in [readyPath, continuePath] where fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
        guard fileManager.createFile(atPath: readyPath, contents: Data()) else {
            throw SignalCreationError()
        }
        defer {
            for path in [readyPath, continuePath]
            where fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
            }
        }

        for _ in 0..<attempts {
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: continuePath) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TimedOut()
    }

    private static func signalPath(for environmentKey: String) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment[environmentKey],
              !path.isEmpty,
              let processTemporaryPath = environment["TMPDIR"],
              !processTemporaryPath.isEmpty
        else {
            throw ConfigurationError()
        }
        return try validatedSignalURL(
            path: path,
            processTemporaryPath: processTemporaryPath).path
    }

    static func validatedSignalURL(
        path: String,
        processTemporaryPath: String
    ) throws -> URL {
        let signalURL = URL(fileURLWithPath: path).standardizedFileURL
        let processTemporaryDirectory = URL(
            fileURLWithPath: processTemporaryPath,
            isDirectory: true
        ).standardizedFileURL
            .resolvingSymlinksInPath()
        let signalDirectory = signalURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: processTemporaryDirectory.path,
            isDirectory: &isDirectory),
              isDirectory.boolValue,
              signalDirectory == processTemporaryDirectory,
              signalURL.lastPathComponent.hasPrefix("portavoz-uitest-")
        else {
            throw ConfigurationError()
        }
        return signalURL
    }
}
