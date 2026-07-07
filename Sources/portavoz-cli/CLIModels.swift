import DiarizationKit
import Foundation
import ModelStoreKit
import TranscriptionKit

/// `portavoz-cli models <download|verify|path> [--models-dir <dir>]`
/// Operates on every model in the curated catalog.
enum ModelsCommand {
    static var catalog: [ModelDescriptor] {
        [ModelCatalog.parakeetTdtV3, ModelCatalog.speakerDiarization]
    }

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

        switch action {
        case "path":
            for descriptor in catalog {
                let directory = await store.directory(for: descriptor)
                let report = await store.verify(descriptor)
                print("\(descriptor.displayName)")
                print("  revision:  \(descriptor.revision)")
                print("  directory: \(directory.path)")
                print("  status:    \(report.isComplete ? "installed & verified" : "not installed")")
            }

        case "verify":
            for descriptor in catalog {
                let report = await store.verify(descriptor)
                let ok = descriptor.artifacts.count - report.missing.count - report.corrupted.count
                print("\(descriptor.displayName): \(ok)/\(descriptor.artifacts.count) artifacts verified")
                for path in report.missing { print("  missing:   \(path)") }
                for path in report.corrupted { print("  CORRUPTED: \(path)") }
                if report.isComplete { print("  all sha256 hashes match the pinned registry ✓") }
            }

        case "download":
            do {
                // Download + verify + prove loadable, per model.
                _ = try await CLISupport.loadEngine(store: store)
                print("\(ModelCatalog.parakeetTdtV3.displayName): installed, verified and loadable ✓")

                let diarizer = ModelCatalog.speakerDiarization
                let report = await store.verify(diarizer)
                if !report.isComplete {
                    print("Downloading \(diarizer.displayName) (\(diarizer.totalSizeBytes / 1_000_000) MB, sha256-verified)…")
                }
                _ = try await PyannoteDiarizer.loadRecommended(store: store)
                print("\(diarizer.displayName): installed, verified and loadable ✓")
            } catch {
                print("error: \(error.localizedDescription)")
            }

        default:
            print("Unknown models action: \(action)")
        }
    }
}
