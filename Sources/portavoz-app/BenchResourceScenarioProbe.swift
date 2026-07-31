import Foundation

struct BenchRefineResourceConfiguration: Equatable {
    let fixtureURL: URL
    let timeoutSeconds: Int

    static func requested(
        arguments: [String]
    ) throws -> BenchRefineResourceConfiguration? {
        guard let fixtureIndex = arguments.firstIndex(
            of: "--bench-resource-refine")
        else {
            return nil
        }
        guard arguments.indices.contains(fixtureIndex + 1),
              !arguments[fixtureIndex + 1].isEmpty
        else {
            throw BenchRefineResourceError.missingFixture
        }
        let timeout = try BenchResourceArguments.integer(
            "--bench-resource-timeout",
            arguments: arguments,
            defaultValue: 900,
            allowed: 60...3_600,
            error: BenchRefineResourceError.invalidTimeout)
        return BenchRefineResourceConfiguration(
            fixtureURL: URL(
                fileURLWithPath: arguments[fixtureIndex + 1])
                .standardizedFileURL,
            timeoutSeconds: timeout)
    }
}

struct BenchSummaryResourceConfiguration: Equatable {
    let timeoutSeconds: Int

    static func requested(
        arguments: [String]
    ) throws -> BenchSummaryResourceConfiguration? {
        guard arguments.contains("--bench-resource-summary") else {
            return nil
        }
        return BenchSummaryResourceConfiguration(timeoutSeconds:
            try BenchResourceArguments.integer(
                "--bench-resource-timeout",
                arguments: arguments,
                defaultValue: 900,
                allowed: 60...3_600,
                error: BenchSummaryResourceError.invalidTimeout))
    }
}

struct BenchAskResourceConfiguration: Equatable {
    let timeoutSeconds: Int

    static func requested(
        arguments: [String]
    ) throws -> BenchAskResourceConfiguration? {
        guard arguments.contains("--bench-resource-ask") else {
            return nil
        }
        return BenchAskResourceConfiguration(timeoutSeconds:
            try BenchResourceArguments.integer(
                "--bench-resource-timeout",
                arguments: arguments,
                defaultValue: 900,
                allowed: 60...3_600,
                error: BenchAskResourceError.invalidTimeout))
    }
}

struct BenchIndexingResourceConfiguration: Equatable {
    let timeoutSeconds: Int

    static func requested(
        arguments: [String]
    ) throws -> BenchIndexingResourceConfiguration? {
        guard arguments.contains("--bench-resource-indexing") else {
            return nil
        }
        return BenchIndexingResourceConfiguration(timeoutSeconds:
            try BenchResourceArguments.integer(
                "--bench-resource-timeout",
                arguments: arguments,
                defaultValue: 900,
                allowed: 60...3_600,
                error: BenchIndexingResourceError.invalidTimeout))
    }
}

private enum BenchResourceArguments {
    static func integer<Failure: Error>(
        _ option: String,
        arguments: [String],
        defaultValue: Int,
        allowed: ClosedRange<Int>,
        error: Failure
    ) throws(Failure) -> Int {
        guard let index = arguments.firstIndex(of: option) else {
            return defaultValue
        }
        guard arguments.indices.contains(index + 1),
              let value = Int(arguments[index + 1]),
              allowed.contains(value)
        else {
            throw error
        }
        return value
    }
}

/// One exact resource window around a benchmark-only product workflow.
///
/// The generic lifecycle is shared by Refine and future summary, Ask, and
/// indexing collectors. Scenario requirements remain in the tracked evidence
/// contract and are validated again when the host receipt is assembled.
final class BenchResourceScenarioProbe {
    typealias Readiness = @MainActor @Sendable () async throws -> Void

    private let run: Int
    private let outputDirectory: URL
    private let readiness: Readiness
    private var probe: ResourceRunProbe?
    private var observer: UUID?

    init(
        arguments: [String],
        readiness: @escaping Readiness = {
            try await ResourceProbeHostReadiness.waitUntilNominal()
        }
    ) throws {
        guard let outputIndex = arguments.firstIndex(
            of: "--bench-resource-output"),
              arguments.indices.contains(outputIndex + 1),
              !arguments[outputIndex + 1].isEmpty
        else {
            throw BenchResourceScenarioProbeError.missingOutput
        }
        guard let runIndex = arguments.firstIndex(of: "--bench-resource-run"),
              arguments.indices.contains(runIndex + 1),
              let run = Int(arguments[runIndex + 1]),
              (1...100).contains(run)
        else {
            throw BenchResourceScenarioProbeError.invalidRun
        }
        self.run = run
        outputDirectory = URL(
            fileURLWithPath: arguments[outputIndex + 1],
            isDirectory: true).standardizedFileURL
        self.readiness = readiness
    }

    deinit {
        removeObserver()
    }

    @MainActor
    func measure<Value>(
        scenario: String,
        operation: () async throws -> Value
    ) async throws -> Value {
        try await readiness()
        let probe = try ResourceRunProbe(run: run)
        let observer = AppResourceWorkloadTelemetry.shared.addObserver(
            replayingActive: true
        ) { [weak probe] event in
            probe?.receive(event)
        }
        self.probe = probe
        self.observer = observer
        probe.startSampling()

        do {
            let value = try await operation()
            try probe.stopMeasurement()
            removeObserver()
            try probe.writeSample(
                to: outputDirectory.appendingPathComponent(
                    "\(scenario)-\(run).json"))
            return value
        } catch {
            try? probe.stopMeasurement()
            removeObserver()
            self.probe = nil
            throw error
        }
    }

    func cancel() {
        try? probe?.stopMeasurement()
        removeObserver()
        probe = nil
    }

    private func removeObserver() {
        if let observer {
            AppResourceWorkloadTelemetry.shared.removeObserver(observer)
            self.observer = nil
        }
    }
}

/// Executes one benchmark operation with a real wall-clock bound.
///
/// The first result wins and the caller never awaits a model task that ignores
/// cooperative cancellation. Benchmark processes exit after publishing their
/// exact fragment, so a late result cannot escape into product state.
enum BenchResourceTimedOperation {
    @MainActor
    static func run<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Result<Value>.self)
        let operationTask = Task { @MainActor in
            do {
                continuation.yield(.completed(try await operation()))
            } catch {
                continuation.yield(.failed(error.localizedDescription))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            continuation.yield(.timedOut)
        }
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next() ?? .timedOut
        operationTask.cancel()
        timeoutTask.cancel()
        continuation.finish()

        switch result {
        case .completed(let value):
            return value
        case .failed(let message):
            throw BenchResourceTimedOperationError.operationFailed(message)
        case .timedOut:
            throw BenchResourceTimedOperationError.timedOut
        }
    }

    private enum Result<Value: Sendable>: Sendable {
        case completed(Value)
        case failed(String)
        case timedOut
    }
}

enum BenchResourceTimedOperationError: Error, Equatable {
    case operationFailed(String)
    case timedOut
}

enum BenchResourceScenarioProbeError: Error, Equatable, LocalizedError {
    case invalidRun
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .invalidRun:
            "--bench-resource-run must be between 1 and 100"
        case .missingOutput:
            "--bench-resource-output requires a directory"
        }
    }
}

enum BenchSummaryResourceError: Error, Equatable, LocalizedError {
    case invalidTimeout
    case modelsNotReady
    case operationFailed(String)
    case timedOut(Int)
    case unexpectedResult(String)

    var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            "--bench-resource-timeout must be between 60 and 3600 seconds"
        case .modelsNotReady:
            "the embedded summary model must be verified before resource collection"
        case .operationFailed(let message):
            "Summary resource operation failed: \(message)"
        case .timedOut(let seconds):
            "Summary resource operation exceeded \(seconds) seconds"
        case .unexpectedResult(let result):
            "Summary resource operation returned \(result)"
        }
    }
}

enum BenchAskResourceError: Error, Equatable, LocalizedError {
    case assetsNotReady
    case invalidTimeout
    case noCitations
    case noGeneratedAnswer
    case operationFailed(String)
    case timedOut(Int)

    var errorDescription: String? {
        switch self {
        case .assetsNotReady:
            "Ask requires installed Apple embedding assets and available Foundation Models"
        case .invalidTimeout:
            "--bench-resource-timeout must be between 60 and 3600 seconds"
        case .noCitations:
            "Ask resource operation returned no citations"
        case .noGeneratedAnswer:
            "Ask resource operation returned no generated answer"
        case .operationFailed(let message):
            "Ask resource operation failed: \(message)"
        case .timedOut(let seconds):
            "Ask resource operation exceeded \(seconds) seconds"
        }
    }
}

enum BenchIndexingResourceError: Error, Equatable, LocalizedError {
    case assetsNotReady
    case incomplete(expected: Int, actual: Int)
    case invalidTimeout
    case operationFailed(String)
    case timedOut(Int)

    var errorDescription: String? {
        switch self {
        case .assetsNotReady:
            "Indexing requires installed Apple Latin embedding assets"
        case .incomplete(let expected, let actual):
            "Indexing completed \(actual) of \(expected) fixed segments"
        case .invalidTimeout:
            "--bench-resource-timeout must be between 60 and 3600 seconds"
        case .operationFailed(let message):
            "Indexing resource operation failed: \(message)"
        case .timedOut(let seconds):
            "Indexing resource operation exceeded \(seconds) seconds"
        }
    }
}

enum BenchRefineResourceError: Error, Equatable, LocalizedError {
    case fixtureIsSilent
    case invalidTimeout
    case missingFixture
    case modelsNotReady
    case operationFailed(String)
    case timedOut(Int)

    var errorDescription: String? {
        switch self {
        case .fixtureIsSilent:
            "the Refine resource fixture contains no measurable speech"
        case .invalidTimeout:
            "--bench-resource-timeout must be between 60 and 3600 seconds"
        case .missingFixture:
            "--bench-resource-refine requires an audio fixture"
        case .modelsNotReady:
            "Refine models must be verified before resource collection"
        case .operationFailed(let message):
            "Refine resource operation failed: \(message)"
        case .timedOut(let seconds):
            "Refine resource operation exceeded \(seconds) seconds"
        }
    }
}
