import Foundation
import TranscriptionKit

/// `portavoz-cli models <download|verify|path> [--models-dir <dir>]`
enum ModelsCommand {
    static func run(_ arguments: [String]) async {
        var arguments = arguments
        guard let action = arguments.first else {
            print("Usage: portavoz-cli models <download|verify|path> [--models-dir <dir>]")
            return
        }
        arguments.removeFirst()

        var modelsDir: String?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--models-dir", index + 1 < arguments.count {
                modelsDir = arguments[index + 1]
                index += 1
            }
            index += 1
        }

        let store = CLISupport.modelStore(fromModelsDir: modelsDir)
        guard let descriptor = ModelCatalog.recommended(for: .liveTranscription) else { return }

        switch action {
        case "path":
            let directory = await store.directory(for: descriptor)
            let report = await store.verify(descriptor)
            print("\(descriptor.displayName)")
            print("  revision:  \(descriptor.revision)")
            print("  directory: \(directory.path)")
            print("  status:    \(report.isComplete ? "installed & verified" : "not installed")")

        case "verify":
            let report = await store.verify(descriptor)
            let ok = descriptor.artifacts.count - report.missing.count - report.corrupted.count
            print("\(descriptor.displayName): \(ok)/\(descriptor.artifacts.count) artifacts verified")
            for path in report.missing { print("  missing:   \(path)") }
            for path in report.corrupted { print("  CORRUPTED: \(path)") }
            if report.isComplete { print("  all sha256 hashes match the pinned registry ✓") }

        case "download":
            do {
                _ = try await CLISupport.loadEngine(store: store)
                print("Model installed, verified and loadable ✓")
            } catch {
                print("error: \(error.localizedDescription)")
            }

        default:
            print("Unknown models action: \(action)")
        }
    }
}
