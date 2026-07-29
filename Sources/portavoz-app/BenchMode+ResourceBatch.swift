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
/// The recording runner prepares the shared Parakeet engine before opening its
/// metric window. Only the utility-priority file transcription executes while
/// capture is active, so the sample measures interference rather than model
/// installation or loading.
struct BenchBatchResourceWorkload {
    let configuration: BenchBatchResourceConfiguration

    @MainActor
    func run(
        services: AppServices,
        timeoutSeconds: Int
    ) async throws -> FileTranscription {
        let transcriber = try await services.loadTranscriberIfNeeded(
            workloadClass: .postCapture)
        do {
            return try await BenchResourceTimedOperation.run(
                timeout: .seconds(timeoutSeconds)
            ) {
                try await services.transcriptionScheduler.batch(
                    workloadClass: .postCapture
                ) {
                    try await transcriber.transcribeFile(
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
        // Resolve and load the same shared engine before the concurrent probe
        // starts. A missing model fails the run rather than becoming measured
        // download/setup noise.
        _ = try await services.loadTranscriberIfNeeded(
            workloadClass: .postCapture)
        return BenchBatchResourceWorkload(
            configuration: configuration)
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
