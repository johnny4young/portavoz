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
        let timeout = try integerArgument(
            "--bench-resource-timeout",
            arguments: arguments,
            defaultValue: 900,
            allowed: 60...3_600)
        return BenchRefineResourceConfiguration(
            fixtureURL: URL(
                fileURLWithPath: arguments[fixtureIndex + 1])
                .standardizedFileURL,
            timeoutSeconds: timeout)
    }

    private static func integerArgument(
        _ option: String,
        arguments: [String],
        defaultValue: Int,
        allowed: ClosedRange<Int>
    ) throws -> Int {
        guard let index = arguments.firstIndex(of: option) else {
            return defaultValue
        }
        guard arguments.indices.contains(index + 1),
              let value = Int(arguments[index + 1]),
              allowed.contains(value)
        else {
            throw BenchRefineResourceError.invalidTimeout
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
    private let run: Int
    private let outputDirectory: URL
    private var probe: ResourceRunProbe?
    private var observer: UUID?

    init(arguments: [String]) throws {
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
    }

    deinit {
        removeObserver()
    }

    @MainActor
    func measure<Value>(
        scenario: String,
        operation: () async throws -> Value
    ) async throws -> Value {
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
