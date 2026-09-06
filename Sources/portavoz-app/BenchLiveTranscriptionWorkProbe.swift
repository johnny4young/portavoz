import Foundation
import os
import PortavozCore
import TranscriptionKit

/// Diagnostic sidecar, not a replacement for resource or candidate authority.
/// Its two terminal samples expose only public-adapter work, never source text.
final class BenchLiveTranscriptionWorkProbe: Sendable {
    struct Document: Codable {
        let schemaVersion: Int
        let kind: String
        let run: Int
        let scenario: String
        let expectedInputFramesPerChannel: Int
        let backendAttemptCountsAvailable: Bool
        let observationComplete: Bool
        let ownerCompleted: Bool
        let overflowed: Bool
        let samples: [ParakeetLiveWorkSample]
    }

    private struct State {
        var samples: [ParakeetLiveWorkSample] = []
        var overflow = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let output: URL
    private let run: Int
    private let scenario: String
    private let expectedFrames: Int

    static func requested(arguments: [String], durationSeconds: Int) throws -> BenchLiveTranscriptionWorkProbe? {
        guard arguments.contains("--bench-resource-live-work") else { return nil }
        return try Self(arguments: arguments, durationSeconds: durationSeconds)
    }

    init(arguments: [String], durationSeconds: Int) throws {
        guard ["--bench-resource-live-work", "--bench-resource-run", "--bench-resource-output"]
            .allSatisfy({ flag in arguments.filter { $0 == flag }.count == 1 }),
              try BenchSyntheticCapturePolicy.validateResourceRequest(arguments: arguments),
              try BenchRecordingResourcePolicy.duration(arguments: arguments) == durationSeconds,
              let frames = BenchSyntheticCapturePolicy.expectedFrames(durationSeconds: durationSeconds),
              let runIndex = arguments.firstIndex(of: "--bench-resource-run"),
              arguments.indices.contains(runIndex + 1),
              let run = Int(arguments[runIndex + 1]), (1...100).contains(run),
              let outputIndex = arguments.firstIndex(of: "--bench-resource-output"),
              arguments.indices.contains(outputIndex + 1),
              arguments[outputIndex + 1].hasPrefix("/")
        else { throw BenchLiveWorkError.invalidRequest }
        let indexing = arguments.contains("--bench-resource-recording-indexing")
        let batch = arguments.contains("--bench-resource-recording-batch")
        guard !(indexing && batch) else { throw BenchLiveWorkError.invalidRequest }
        scenario = indexing ? "recording-plus-indexing" : batch ? "recording-plus-batch" : "recording"
        self.run = run
        expectedFrames = Int(frames)
        output = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
            .appendingPathComponent("\(scenario)-live-work-\(run).json")
    }

    func receive(_ sample: ParakeetLiveWorkSample) {
        state.withLock { value in
            guard value.samples.count < 2 else {
                value.overflow = true
                return
            }
            value.samples.append(sample)
        }
    }

    func document() throws -> Document {
        let document = diagnosticDocument()
        guard document.observationComplete else { throw BenchLiveWorkError.incompleteObservation }
        return document
    }

    private func diagnosticDocument(ownerCompleted: Bool = true) -> Document {
        let value = state.withLock { $0 }
        let complete = ownerCompleted && !value.overflow && value.samples.count == 2
            && Set(value.samples.compactMap(\.channel)) == Set([.microphone, .system])
            && value.samples.allSatisfy({
                  $0.valid && $0.outcome == .completed && $0.sampleRate == 16_000
                      && $0.inputFrames == expectedFrames && $0.rejectedBuffers == 0
                      && $0.finishCalls == 1
              })
        return Document(
            schemaVersion: 1, kind: "parakeet-live-work", run: run, scenario: scenario,
            expectedInputFramesPerChannel: expectedFrames,
            backendAttemptCountsAvailable: false,
            observationComplete: complete, ownerCompleted: ownerCompleted, overflowed: value.overflow,
            samples: value.samples.sorted { ($0.channel?.rawValue ?? "") < ($1.channel?.rawValue ?? "") })
    }

    func write(ownerCompleted: Bool = true) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let document = diagnosticDocument(ownerCompleted: ownerCompleted)
        let data = try encoder.encode(document) + Data("\n".utf8)
        let adverseOutput = output.deletingPathExtension().appendingPathExtension("adverse.json")
        let destination = document.observationComplete ? output : adverseOutput
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard !FileManager.default.fileExists(atPath: output.path),
              !FileManager.default.fileExists(atPath: adverseOutput.path) else {
            throw BenchLiveWorkError.outputAlreadyExists
        }
        let temporary = directory.appendingPathComponent(".live-work-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw BenchLiveWorkError.writeFailed }
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            // Same-directory hard-link publication is atomic and cannot replace
            // a competing writer's result; the temporary link is always removed.
            try FileManager.default.linkItem(at: temporary, to: destination)
        } catch {
            throw BenchLiveWorkError.writeFailed
        }
        guard document.observationComplete else { throw BenchLiveWorkError.incompleteObservation }
    }
}

enum BenchLiveWorkError: String, Error, LocalizedError {
    case invalidRequest
    case incompleteObservation
    case outputAlreadyExists
    case writeFailed

    var errorDescription: String? { "Live-work diagnostic: \(rawValue)" }
}
