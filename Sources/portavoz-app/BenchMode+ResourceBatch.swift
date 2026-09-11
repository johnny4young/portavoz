import AudioCaptureKit
import Foundation
import PortavozCore
import TranscriptionKit

struct BenchBatchResourceConfiguration {
    let fixtureURL: URL

    static func requested(
        arguments: [String]
    ) throws -> BenchBatchResourceConfiguration? {
        guard let index = arguments.firstIndex(
            of: "--bench-resource-recording-batch")
        else {
            return nil
        }
        guard arguments.indices.contains(index + 1),
              !arguments[index + 1].isEmpty
        else {
            throw BenchBatchResourceError.missingFixture
        }
        let fixtureURL = URL(
            fileURLWithPath: arguments[index + 1]).standardizedFileURL
        guard fixtureURL.isFileURL,
              FileManager.default.fileExists(atPath: fixtureURL.path)
        else {
            throw BenchBatchResourceError.missingFixture
        }
        guard !AudioSilence.fileIsSilent(at: fixtureURL) else {
            throw BenchBatchResourceError.fixtureIsSilent
        }
        return BenchBatchResourceConfiguration(
            fixtureURL: fixtureURL)
    }
}

/// A fixed public audio fixture run through the exact production batch lane.
///
/// The recording runner prepares the shared Parakeet engine and validates one
/// unmeasured file transcription before opening its metric window. The same
/// utility-priority operation then executes while capture is active, so the
/// sample measures steady interference rather than installation, lazy paging,
/// or first-use setup.
struct BenchBatchResourceWorkload {
    let configuration: BenchBatchResourceConfiguration

    @MainActor
    func run(
        services: AppServices,
        timeoutSeconds: Int
    ) async throws -> FileTranscription {
        let runtime = try await services.acquireLiveSpeechRuntime(
            workloadClass: .postCapture)
        defer { _ = services.finishLiveSpeechRuntime(runtime) }
        do {
            return try await BenchResourceTimedOperation.run(
                timeout: .seconds(timeoutSeconds)
            ) {
                try await services.transcriptionScheduler.batch(
                    workloadClass: .postCapture
                ) {
                    try await runtime.engine.transcribeFile(
                        at: configuration.fixtureURL,
                        hints: TranscriptionHints(language: "en"),
                        channel: .system)
                }
            }
        } catch BenchResourceTimedOperationError.operationFailed(let message) {
            throw BenchBatchResourceError.operationFailed(message)
        } catch BenchResourceTimedOperationError.timedOut {
            throw BenchBatchResourceError.timedOut(timeoutSeconds)
        }
    }

    func validate(_ transcription: FileTranscription) throws {
        guard !transcription.text
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              transcription.segments.contains(where: {
                  !$0.text.trimmingCharacters(
                      in: .whitespacesAndNewlines).isEmpty
              })
        else {
            throw BenchBatchResourceError.emptyTranscription
        }
    }
}

extension BenchMode {
    @MainActor
    static func prepareBatchTranscriptionResourceWorkload(
        configuration: BenchBatchResourceConfiguration,
        services: AppServices
    ) async throws -> BenchBatchResourceWorkload {
        // Resolve the shared engine while building the concurrent workload.
        // The runner performs the exact file-transcription warmup only after
        // all recording engines are loaded, immediately before its readiness
        // gate and measured window.
        let runtime = try await services.acquireLiveSpeechRuntime(
            workloadClass: .postCapture)
        _ = services.finishLiveSpeechRuntime(runtime)
        return BenchBatchResourceWorkload(configuration: configuration)
    }
}

enum BenchBatchResourceError:
    Error,
    Equatable,
    LocalizedError {
    case emptyTranscription
    case fixtureIsSilent
    case missingFixture
    case operationFailed(String)
    case timedOut(Int)

    var errorDescription: String? {
        switch self {
        case .emptyTranscription:
            "batch transcription produced no speech"
        case .fixtureIsSilent:
            "batch transcription fixture is silent"
        case .missingFixture:
            "--bench-resource-recording-batch requires an audio fixture"
        case .operationFailed(let message):
            "batch transcription failed: \(message)"
        case .timedOut(let seconds):
            "batch transcription exceeded \(seconds) seconds"
        }
    }
}
