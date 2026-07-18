import ApplicationKit
import Foundation

/// `portavoz-cli models <download|verify|path> [--models-dir <dir>]`
/// Operates on every model in the curated catalog.
enum ModelsCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity
    static func run(
        _ arguments: [String],
        platform: CLIPlatformDependencies
    ) async {
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

        let workflow = platform.localModels(modelsDirectory: modelsDir)

        switch action {
        case "path":
            do {
                guard case .inspected(let reports) = try await workflow.execute(.init(
                    action: .paths))
                else { return }
                for report in reports {
                    print("\(report.descriptor.displayName)")
                    print("  revision:  \(report.descriptor.revision)")
                    print("  directory: \(report.directory.path)")
                    print("  status:    \(report.isComplete ? "installed & verified" : "not installed")")
                }
            } catch {
                print("error: \(error.localizedDescription)")
            }

        case "verify":
            do {
                guard case .inspected(let reports) = try await workflow.execute(.init(
                    action: .verify))
                else { return }
                for report in reports {
                    let descriptor = report.descriptor
                    print("\(descriptor.displayName): \(report.verifiedArtifactCount)/\(descriptor.artifactCount) artifacts verified")
                    for path in report.missing { print("  missing:   \(path)") }
                    for path in report.corrupted { print("  CORRUPTED: \(path)") }
                    if report.isComplete {
                        print("  all sha256 hashes match the pinned registry ✓")
                    }
                }
            } catch {
                print("error: \(error.localizedDescription)")
            }

        case "download":
            do {
                _ = try await workflow.execute(.init(action: .download) { progress in
                    Self.printProgress(progress)
                })
            } catch {
                print("error: \(error.localizedDescription)")
            }

        default:
            print("Unknown models action: \(action)")
        }
    }

    private static func printProgress(_ progress: AudioAnalysisProgress) {
        switch progress {
        case .downloadingModel(let name, let megabytes):
            print("Downloading \(name) (\(megabytes) MB, sha256-verified)…")
        case .downloadProgress(let percent, let path):
            print("\r  \(percent)% \(path)", terminator: percent == 100 ? "\n" : "")
            fflush(stdout)
        case .loadingTranscriptionModel:
            print("Loading models (first load compiles for the ANE; can take ~a minute)…")
        case .installedModel(let name):
            print("\(name): installed, verified and loadable ✓")
        default:
            break
        }
    }
}
