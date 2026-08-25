import Darwin
import Foundation

/// Runs real recording-only and recording-plus-work resource evidence.
///
/// Preparation happens before a measured window. Concurrent work begins only
/// after Start succeeds, remains inside the active recording lifetime, and
/// freezes before product Stop so the scenarios stay independently attributable.
enum BenchRecordingResourceRunner {
    private struct Configuration {
        let seconds: Int
        let usesSyntheticCapture: Bool
        let baselineProbes: BenchRecordResourceProbes?
        let concurrentProbe: BenchConcurrentRecordingResourceProbe?
        let batchConfiguration: BenchBatchResourceConfiguration?
    }

    @MainActor
    static func runIfRequested(
        services: AppServices,
        recording: RecordingController
    ) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--bench-record") else {
            return
        }
        guard arguments.contains("-use-temp-store") else {
            emit("bench-record: -use-temp-store is required")
            exit(1)
        }
        let seconds: Int
        let configuration: Configuration
        do {
            seconds = try BenchRecordingResourcePolicy.duration(
                arguments: arguments)
            let usesSyntheticCapture = try BenchSyntheticCapturePolicy
                .validateResourceRequest(arguments: arguments)
            let batchConfiguration = try BenchBatchResourceConfiguration
                .requested(arguments: arguments)
            let concurrentProbe = try BenchConcurrentRecordingResourceProbe
                .requested(arguments: arguments)
            let baselineProbes: BenchRecordResourceProbes? = if concurrentProbe == nil {
                try BenchRecordResourceProbes.requested(arguments: arguments)
            } else {
                nil
            }
            configuration = Configuration(
                seconds: seconds,
                usesSyntheticCapture: usesSyntheticCapture,
                baselineProbes: baselineProbes,
                concurrentProbe: concurrentProbe,
                batchConfiguration: batchConfiguration)
        } catch {
            emit(
                "bench-record: resource probe setup FAILED: "
                    + error.localizedDescription)
            exit(1)
        }

        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                try await execute(
                    services: services,
                    recording: recording,
                    configuration: configuration)
                exit(0)
            } catch {
                configuration.baselineProbes?.cancel()
                configuration.concurrentProbe?.cancel()
                if recording.phase == .recording {
                    _ = await stopRecording(
                        recording,
                        services: services,
                        timeout: .seconds(30))
                }
                emit("bench-record: FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    @MainActor
    private static func execute(
        services: AppServices,
        recording: RecordingController,
        configuration: Configuration
    ) async throws {
        if configuration.usesSyntheticCapture {
            emit(
                "bench-record: capture input "
                    + BenchSyntheticCapturePolicy.generation)
        } else if !(await services.authorizeMicrophoneForRecording()) {
            throw BenchRecordingResourceRunnerError.microphonePermissionRequired
        }
        let concurrentWorkload = try await prepareConcurrentWorkload(
            services: services,
            arguments: ProcessInfo.processInfo.arguments,
            batchConfiguration: configuration.batchConfiguration)

        try await prepareRecording(
            services: services,
            recording: recording,
            baselineProbes: configuration.baselineProbes,
            concurrentProbe: configuration.concurrentProbe)

        let concurrentTask = concurrentWorkload.map { workload in
            Task { @MainActor in
                guard let concurrentProbe = configuration.concurrentProbe else {
                    throw BenchConcurrentProbeError
                        .incompleteLifecycle
                }
                return try await workload.run(
                    services: services,
                    timeoutSeconds: concurrentProbe.timeoutSeconds)
            }
        }
        let peak = await sampleRecordingFootprint(
            seconds: configuration.seconds)
        if let concurrentTask {
            emit(try await concurrentTask.value)
        }
        emit(String(
            format: "bench-record: peak footprint %.0f MB over %d s",
            peak,
            configuration.seconds))

        try await finishRecording(
            services: services,
            recording: recording,
            baselineProbes: configuration.baselineProbes,
            concurrentProbe: configuration.concurrentProbe)
    }

    @MainActor
    private static func prepareConcurrentWorkload(
        services: AppServices,
        arguments: [String],
        batchConfiguration: BenchBatchResourceConfiguration?
    ) async throws -> BenchConcurrentRecordingWorkload? {
        if arguments.contains("--bench-resource-recording-indexing") {
            emit("bench-record: preparing semantic indexing fixture")
            return .indexing(try await BenchMode
                .prepareIndexingResourceWorkload(services: services))
        }
        if let batchConfiguration {
            emit("bench-record: preparing batch transcription fixture")
            return .batch(try await BenchMode
                .prepareBatchTranscriptionResourceWorkload(
                    configuration: batchConfiguration,
                    services: services))
        }
        return nil
    }

    @MainActor
    private static func prepareRecording(
        services: AppServices,
        recording: RecordingController,
        baselineProbes: BenchRecordResourceProbes?,
        concurrentProbe: BenchConcurrentRecordingResourceProbe?
    ) async throws {
        emit(String(
            format: "bench-record: baseline (no models) %.0f MB",
            physicalFootprintMB()))
        if let baselineProbes {
            emit(
                "bench-record: settling launch, then sampling idle for "
                    + "\(baselineProbes.idleDurationSeconds) s")
            try await baselineProbes.measureIdle()
            emit("bench-record: idle resource sample complete")
        }
        try await services.loadEnginesIfNeeded()
        try await ResourceProbeHostReadiness.waitUntilNominal()
        try baselineProbes?.beginRecording()
        try concurrentProbe?.begin()
        emit(String(
            format: "bench-record: engines loaded (Parakeet + pyannote) %.0f MB",
            physicalFootprintMB()))
        await recording.start(services: services)
        if case .failed(let reason) = recording.phase {
            throw BenchRecordingResourceRunnerError.startFailed(reason)
        }
    }

    private static func sampleRecordingFootprint(seconds: Int) async -> Double {
        emit(
            "bench-record: recording started, sampling footprint for "
                + "\(seconds) s")
        var peak: Double = 0
        for _ in 0..<(seconds / 2) {
            try? await Task.sleep(for: .seconds(2))
            peak = max(peak, physicalFootprintMB())
        }
        if !seconds.isMultiple(of: 2) {
            try? await Task.sleep(for: .seconds(1))
            peak = max(peak, physicalFootprintMB())
        }
        return peak
    }

    @MainActor
    private static func finishRecording(
        services: AppServices,
        recording: RecordingController,
        baselineProbes: BenchRecordResourceProbes?,
        concurrentProbe: BenchConcurrentRecordingResourceProbe?
    ) async throws {
        try baselineProbes?.finishRecordingAndBeginStop()
        try concurrentProbe?.freezeBeforeStop()
        guard await stopRecording(
            recording,
            services: services,
            timeout: .seconds(30)
        ) else {
            throw BenchRecordingResourceRunnerError.stopTimedOut
        }
        try baselineProbes?.finishStopAndWrite()
        try concurrentProbe?.finishAfterStopAndWrite()
        try? await Task.sleep(for: .seconds(3))
        emit(String(
            format: "bench-record: after stop %.0f MB",
            physicalFootprintMB()))
        services.releaseRecordingEngines()
        await sampleReleasedEngineFootprint()
    }

    private static func sampleReleasedEngineFootprint() async {
        // CoreML gives pages back lazily — sample twice so a slow reclaim is
        // not mistaken for a leak.
        try? await Task.sleep(for: .seconds(3))
        emit(String(
            format: "bench-record: after engine release (3 s) %.0f MB",
            physicalFootprintMB()))
        try? await Task.sleep(for: .seconds(12))
        emit(String(
            format: "bench-record: after engine release (15 s) %.0f MB",
            physicalFootprintMB()))
    }

    /// An unstructured first-result stream is intentional. A task group would
    /// wait for a cancelled Stop child before leaving scope and therefore
    /// would not enforce the timeout. A timed-out bench exits without evidence.
    @MainActor
    private static func stopRecording(
        _ recording: RecordingController,
        services: AppServices,
        timeout: Duration
    ) async -> Bool {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        let stopTask = Task { @MainActor in
            await recording.stop(services: services)
            continuation.yield(true)
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(false)
        }
        var iterator = stream.makeAsyncIterator()
        let completed = await iterator.next() ?? false
        stopTask.cancel()
        timeoutTask.cancel()
        continuation.finish()
        return completed
    }

    private static func emit(_ line: String) {
        print(line)
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--bench-log"),
              arguments.indices.contains(flag + 1)
        else {
            return
        }
        let url = URL(fileURLWithPath: arguments[flag + 1])
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func physicalFootprintMB() -> Double {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) { reboundPointer in
                proc_pid_rusage(
                    getpid(),
                    RUSAGE_INFO_CURRENT,
                    reboundPointer)
            }
        }
        guard result == 0 else { return 0 }
        return Double(usage.ri_phys_footprint) / 1_048_576
    }
}

enum BenchRecordingResourcePolicy {
    static func duration(arguments: [String]) throws -> Int {
        let indexes = arguments.indices.filter {
            arguments[$0] == "--bench-record"
        }
        guard indexes.count == 1,
              let index = indexes.first,
              arguments.indices.contains(index + 1),
              let seconds = Int(arguments[index + 1]),
              (30...600).contains(seconds)
        else {
            throw BenchRecordingResourceRunnerError.invalidDuration
        }
        return seconds
    }
}

private enum BenchConcurrentRecordingWorkload {
    case batch(BenchBatchResourceWorkload)
    case indexing(BenchIndexingResourceWorkload)

    @MainActor
    func run(
        services: AppServices,
        timeoutSeconds: Int
    ) async throws -> String {
        switch self {
        case .batch(let workload):
            let result = try await workload.run(
                services: services,
                timeoutSeconds: timeoutSeconds)
            try workload.validate(result)
            return "bench-record: concurrent batch transcription complete"
        case .indexing(let workload):
            let result = try await workload.run(
                timeoutSeconds: timeoutSeconds)
            try await workload.validate(
                result,
                store: services.store)
            return "bench-record: concurrent semantic indexing complete"
        }
    }
}

enum BenchRecordingResourceRunnerError: Error, Equatable, LocalizedError {
    case invalidDuration
    case microphonePermissionRequired
    case startFailed(String)
    case stopTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            "--bench-record must occur once with a duration between 30 and 600 seconds"
        case .microphonePermissionRequired:
            "grant microphone access to Portavoz Resource Bench and rerun"
        case .startFailed(let reason):
            "recording start failed: \(reason)"
        case .stopTimedOut:
            "recording Stop exceeded 30 seconds"
        }
    }
}
