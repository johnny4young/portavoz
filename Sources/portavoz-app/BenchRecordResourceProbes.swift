import Foundation

/// Optional structured evidence around the existing real recording bench.
/// One invocation writes independent idle, active-recording, and Stop
/// fragments; tooling later assembles repeated runs into a host receipt.
final class BenchRecordResourceProbes {
    let idleDurationSeconds: Int

    private let run: Int
    private let outputDirectory: URL
    private var idleProbe: ResourceRunProbe?
    private var idleObserver: UUID?
    private var recordingProbe: ResourceRunProbe?
    private var recordingObserver: UUID?
    private var stopProbe: ResourceRunProbe?
    private var stopObserver: UUID?

    static func requested(arguments: [String]) throws -> BenchRecordResourceProbes? {
        guard let outputIndex = arguments.firstIndex(
            of: "--bench-resource-output")
        else {
            return nil
        }
        guard arguments.indices.contains(outputIndex + 1),
              !arguments[outputIndex + 1].isEmpty
        else {
            throw BenchRecordResourceProbeError.missingOutput
        }
        guard let runIndex = arguments.firstIndex(of: "--bench-resource-run"),
              arguments.indices.contains(runIndex + 1),
              let run = Int(arguments[runIndex + 1]),
              (1...100).contains(run)
        else {
            throw BenchRecordResourceProbeError.invalidRun
        }
        let idleDurationSeconds = try integerArgument(
            "--bench-resource-idle-duration",
            arguments: arguments,
            defaultValue: 30,
            allowed: 10...600)
        return BenchRecordResourceProbes(
            run: run,
            idleDurationSeconds: idleDurationSeconds,
            outputDirectory: URL(
                fileURLWithPath: arguments[outputIndex + 1],
                isDirectory: true).standardizedFileURL)
    }

    private init(
        run: Int,
        idleDurationSeconds: Int,
        outputDirectory: URL
    ) {
        self.run = run
        self.idleDurationSeconds = idleDurationSeconds
        self.outputDirectory = outputDirectory
    }

    deinit {
        removeObservers()
    }

    /// Let launch-only work settle, then measure a model-free idle window
    /// before recording engines are loaded.
    @MainActor
    func measureIdle() async throws {
        try await Task.sleep(for: .seconds(5))
        let probe = try ResourceRunProbe(run: run)
        let observer = AppResourceWorkloadTelemetry.shared.addObserver(
            replayingActive: true
        ) { [weak probe] event in
            probe?.receive(event)
        }
        idleProbe = probe
        idleObserver = observer
        probe.startSampling()
        do {
            try await Task.sleep(for: .seconds(idleDurationSeconds))
            try probe.stopMeasurement()
            removeIdleObserver()
        } catch {
            try? probe.stopMeasurement()
            removeIdleObserver()
            idleProbe = nil
            throw error
        }
    }

    func beginRecording() throws {
        let probe = try ResourceRunProbe(run: run)
        let observer = AppResourceWorkloadTelemetry.shared.addObserver { [weak probe] event in
            probe?.receive(event)
        }
        recordingProbe = probe
        recordingObserver = observer
        probe.startSampling()
    }

    /// Freeze active-recording metrics before Stop begins, while preserving
    /// the already-open live-transcription spans until stream teardown.
    func finishRecordingAndBeginStop() throws {
        let probe = try ResourceRunProbe(run: run)
        let observer = AppResourceWorkloadTelemetry.shared.addObserver(
            replayingActive: true
        ) { [weak probe] event in
            probe?.receive(event)
        }
        stopProbe = probe
        stopObserver = observer
        probe.startSampling()
        // Arm Stop first so spans already active at the phase boundary are
        // replayed and no finish can fall between the two collectors.
        try recordingProbe?.stopMeasurement()
    }

    func finishStopAndWrite() throws {
        try stopProbe?.stopMeasurement()
        removeObservers()
        guard let idleProbe, let recordingProbe, let stopProbe else {
            throw BenchRecordResourceProbeError.incompleteLifecycle
        }
        try idleProbe.writeSample(
            to: outputDirectory.appendingPathComponent(
                "idle-\(run).json"))
        try recordingProbe.writeSample(
            to: outputDirectory.appendingPathComponent(
                "recording-\(run).json"))
        try stopProbe.writeSample(
            to: outputDirectory.appendingPathComponent(
                "stop-\(run).json"))
    }

    func cancel() {
        try? idleProbe?.stopMeasurement()
        try? recordingProbe?.stopMeasurement()
        try? stopProbe?.stopMeasurement()
        removeObservers()
        idleProbe = nil
        recordingProbe = nil
        stopProbe = nil
    }

    private func removeObservers() {
        removeIdleObserver()
        if let recordingObserver {
            AppResourceWorkloadTelemetry.shared.removeObserver(recordingObserver)
            self.recordingObserver = nil
        }
        if let stopObserver {
            AppResourceWorkloadTelemetry.shared.removeObserver(stopObserver)
            self.stopObserver = nil
        }
    }

    private func removeIdleObserver() {
        if let idleObserver {
            AppResourceWorkloadTelemetry.shared.removeObserver(idleObserver)
            self.idleObserver = nil
        }
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
            throw BenchRecordResourceProbeError.invalidIdleDuration
        }
        return value
    }
}

enum BenchRecordResourceProbeError: Error, Equatable, LocalizedError {
    case incompleteLifecycle
    case invalidIdleDuration
    case invalidRun
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .incompleteLifecycle:
            "resource probes did not complete idle, recording, and Stop"
        case .invalidIdleDuration:
            "--bench-resource-idle-duration must be between 10 and 600 seconds"
        case .invalidRun:
            "--bench-resource-run must be between 1 and 100"
        case .missingOutput:
            "--bench-resource-output requires a directory"
        }
    }
}

/// One concurrent recording scenario. The metric window opens before Start,
/// freezes before Stop, and stays subscribed until live spans finish during
/// teardown. This keeps Stop work out while retaining the recording work that
/// was active inside the measured window.
final class BenchConcurrentRecordingResourceProbe {
    let timeoutSeconds: Int

    private let run: Int
    private let scenario: String
    private let outputDirectory: URL
    private var probe: ResourceRunProbe?
    private var observer: UUID?

    static func recordingIndexingRequested(
        arguments: [String]
    ) throws -> BenchConcurrentRecordingResourceProbe? {
        guard arguments.contains("--bench-resource-recording-indexing") else {
            return nil
        }
        guard let outputIndex = arguments.firstIndex(
            of: "--bench-resource-output"),
              arguments.indices.contains(outputIndex + 1),
              !arguments[outputIndex + 1].isEmpty
        else {
            throw BenchConcurrentProbeError.missingOutput
        }
        guard let runIndex = arguments.firstIndex(of: "--bench-resource-run"),
              arguments.indices.contains(runIndex + 1),
              let run = Int(arguments[runIndex + 1]),
              (1...100).contains(run)
        else {
            throw BenchConcurrentProbeError.invalidRun
        }
        let timeoutSeconds = try integerArgument(
            "--bench-resource-timeout",
            arguments: arguments,
            defaultValue: 900,
            allowed: 60...3_600)
        return BenchConcurrentRecordingResourceProbe(
            run: run,
            scenario: "recording-indexing",
            timeoutSeconds: timeoutSeconds,
            outputDirectory: URL(
                fileURLWithPath: arguments[outputIndex + 1],
                isDirectory: true).standardizedFileURL)
    }

    private init(
        run: Int,
        scenario: String,
        timeoutSeconds: Int,
        outputDirectory: URL
    ) {
        self.run = run
        self.scenario = scenario
        self.timeoutSeconds = timeoutSeconds
        self.outputDirectory = outputDirectory
    }

    deinit {
        removeObserver()
    }

    func begin() throws {
        let probe = try ResourceRunProbe(run: run)
        let observer = AppResourceWorkloadTelemetry.shared.addObserver { [weak probe] event in
            probe?.receive(event)
        }
        self.probe = probe
        self.observer = observer
        probe.startSampling()
    }

    /// Process counters freeze before Stop, but the observer remains installed
    /// so already-open live-transcription spans can publish their terminal
    /// outcome during teardown.
    func freezeBeforeStop() throws {
        guard let probe else {
            throw BenchConcurrentProbeError.incompleteLifecycle
        }
        try probe.stopMeasurement()
    }

    func finishAfterStopAndWrite() throws {
        removeObserver()
        guard let probe else {
            throw BenchConcurrentProbeError.incompleteLifecycle
        }
        try probe.writeSample(
            to: outputDirectory.appendingPathComponent(
                "\(scenario)-\(run).json"))
        self.probe = nil
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
            throw BenchConcurrentProbeError.invalidTimeout
        }
        return value
    }
}

enum BenchConcurrentProbeError: Error, Equatable, LocalizedError {
    case incompleteLifecycle
    case invalidRun
    case invalidTimeout
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .incompleteLifecycle:
            "concurrent recording resource probe did not complete"
        case .invalidRun:
            "--bench-resource-run must be between 1 and 100"
        case .invalidTimeout:
            "--bench-resource-timeout must be between 60 and 3600 seconds"
        case .missingOutput:
            "--bench-resource-output requires a directory"
        }
    }
}
