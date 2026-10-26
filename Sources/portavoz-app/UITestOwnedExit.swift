#if DEBUG
import AppKit
import Darwin

/// No input or external process control: a disposable Debug UI host can end
/// itself through AppKit after its owning runner publishes a per-launch request.
@MainActor
enum UITestOwnedExit {
    private static var source: (any DispatchSourceFileSystemObject)?

    static func installIfRequested() {
        let process = ProcessInfo.processInfo
        guard source == nil,
              let configuration = configuration(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                arguments: process.arguments, environment: process.environment) else { return }
        let (nonce, root) = configuration
        let directory = open(root, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return }
        var metadata = stat()
        guard fstat(directory, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o777 == 0o700,
              metadata.st_uid == getuid() else {
            close(directory)
            return
        }
        let expected = Data("\(nonce):\(getpid())".utf8)
        let requestName = "portavoz-uitest-exit-\(nonce)"
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directory, eventMask: .write, queue: .main)
        watcher.setEventHandler {
            // The handler runs on the main queue, the AppKit executor.
            MainActor.assumeIsolated {
                guard validRequest(directory: directory, name: requestName, expected: expected) else { return }
                source?.cancel()
                source = nil
                // AppKit defers termination behind a modal session/sheet.
                // Do not dismiss it or spend the exit deadline discovering
                // that refusal: acknowledge it for official XCTest cleanup.
                if NSApp.modalWindow != nil || NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
                    let declined = URL(fileURLWithPath: root)
                        .appendingPathComponent("portavoz-uitest-exit-declined-\(nonce)")
                    publish(expected, to: declined)
                    return
                }
                NSApp.terminate(nil)
            }
        }
        watcher.setCancelHandler { close(directory) }
        source = watcher
        watcher.resume()
        let ready = URL(fileURLWithPath: root).appendingPathComponent("portavoz-uitest-exit-ready-\(nonce)")
        // The runner allocated this owner-only root. Publish only after the
        // source is armed, so no request is lost between readiness and watching.
        publish(expected, to: ready)
    }

    private static func publish(_ data: Data, to destination: URL) {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("portavoz-uitest-signal-stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        if FileManager.default.createFile(atPath: staging.path, contents: data,
                                          attributes: [.posixPermissions: 0o600]) {
            try? FileManager.default.moveItem(at: staging, to: destination)
        }
    }

    static func configuration(
        bundleIdentifier: String?, arguments: [String], environment: [String: String]
    ) -> (nonce: String, root: String)? {
        guard bundleIdentifier == "app.portavoz.mac.uitest-host",
              arguments.contains("-use-temp-store"),
              arguments.contains("-uitest-owned-exit"),
              let nonce = environment["PORTAVOZ_UI_TEST_EXIT_NONCE"],
              UUID(uuidString: nonce) != nil,
              let root = environment["TMPDIR"], root.hasPrefix("/"), root != "/" else { return nil }
        return (nonce, root)
    }

    static func validRequest(directory: Int32, name: String, expected: Data) -> Bool {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_mode & 0o077 == 0,
              metadata.st_size == expected.count else { return false }
        var data = Data(count: expected.count)
        let count = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        return count == expected.count && data == expected
    }
}
#endif
