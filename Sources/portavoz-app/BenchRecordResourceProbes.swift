import Foundation

/// Optional structured evidence around the existing real recording bench.
/// One invocation writes independent active-recording and Stop fragments;
/// tooling later assembles fragments from repeated runs into a host receipt.
final class BenchRecordResourceProbes {
    private let run: Int
    private let outputDirectory: URL
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
        return BenchRecordResourceProbes(
            run: run,
            outputDirectory: URL(
                fileURLWithPath: arguments[outputIndex + 1],
                isDirectory: true).standardizedFileURL)
    }

    private init(run: Int, outputDirectory: URL) {
        self.run = run
        self.outputDirectory = outputDirectory
    }

    deinit {
        removeObservers()
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
        guard let recordingProbe, let stopProbe else {
            throw BenchRecordResourceProbeError.incompleteLifecycle
        }
        try recordingProbe.writeSample(
            to: outputDirectory.appendingPathComponent(
                "recording-\(run).json"))
        try stopProbe.writeSample(
            to: outputDirectory.appendingPathComponent(
                "stop-\(run).json"))
    }

    func cancel() {
        removeObservers()
    }

    private func removeObservers() {
        if let recordingObserver {
            AppResourceWorkloadTelemetry.shared.removeObserver(recordingObserver)
            self.recordingObserver = nil
        }
        if let stopObserver {
            AppResourceWorkloadTelemetry.shared.removeObserver(stopObserver)
            self.stopObserver = nil
        }
    }
}

enum BenchRecordResourceProbeError: Error, LocalizedError {
    case incompleteLifecycle
    case invalidRun
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .incompleteLifecycle:
            "recording resource probes did not complete both phases"
        case .invalidRun:
            "--bench-resource-run must be between 1 and 100"
        case .missingOutput:
            "--bench-resource-output requires a directory"
        }
    }
}
