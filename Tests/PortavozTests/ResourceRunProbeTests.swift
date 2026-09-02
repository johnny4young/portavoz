import ApplicationKit
import Foundation
import PortavozCore
import XCTest
@testable import portavoz_app

final class ResourceRunProbeTests: XCTestCase {
    func testSyntheticResourceCaptureRequiresTheCompleteDisposableAdmission() throws {
        let admitted = [
            "Portavoz",
            "-use-temp-store",
            "--bench-record", "60",
            "--bench-resource-output", "/tmp/fragments",
            "--bench-resource-synthetic-capture",
        ]
        XCTAssertTrue(BenchSyntheticCapturePolicy.requested(
            arguments: admitted))
        XCTAssertTrue(try BenchSyntheticCapturePolicy.validateResourceRequest(
            arguments: admitted))
        XCTAssertFalse(try BenchSyntheticCapturePolicy.validateResourceRequest(
            arguments: ["Portavoz", "--bench-record", "60"]))
        XCTAssertThrowsError(try BenchSyntheticCapturePolicy
            .validateResourceRequest(arguments: [
                "Portavoz",
                "-use-temp-store",
                "--bench-record", "60",
                "--bench-resource-output", "/tmp/fragments",
            ])) { error in
                XCTAssertEqual(
                    error as? BenchSyntheticCaptureError,
                    .syntheticInputRequired)
            }
        XCTAssertThrowsError(try BenchSyntheticCapturePolicy
            .validateResourceRequest(arguments: [
                "Portavoz",
                "--bench-resource-synthetic-capture",
            ])) { error in
                XCTAssertEqual(
                    error as? BenchSyntheticCaptureError,
                    .invalidAdmission)
            }
        XCTAssertThrowsError(try BenchSyntheticCapturePolicy
            .validateResourceRequest(arguments: admitted + [
                "--bench-resource-synthetic-capture",
            ])) { error in
                XCTAssertEqual(
                    error as? BenchSyntheticCaptureError,
                    .syntheticInputRequired)
            }
    }

    func testRecordingResourceDurationIsUniqueAndBounded() throws {
        XCTAssertEqual(
            try BenchRecordingResourcePolicy.duration(arguments: [
                "Portavoz", "--bench-record", "31",
            ]),
            31)
        for arguments in [
            ["Portavoz"],
            ["Portavoz", "--bench-record"],
            ["Portavoz", "--bench-record", "invalid"],
            ["Portavoz", "--bench-record", "29"],
            ["Portavoz", "--bench-record", "601"],
            [
                "Portavoz", "--bench-record", "60",
                "--bench-record", "60",
            ],
        ] {
            XCTAssertThrowsError(try BenchRecordingResourcePolicy
                .duration(arguments: arguments)) { error in
                    XCTAssertEqual(
                        error as? BenchRecordingResourceRunnerError,
                        .invalidDuration)
                }
        }
    }

    func testSyntheticCapturePublishesBoundedContentFreePCMAndStops() async throws {
        let expectedFrames = Int64(BenchSyntheticCapturePolicy.chunkFrames * 3)
        let source = try XCTUnwrap(BenchSyntheticAudioCaptureSource(
            channel: .microphone,
            expectedFrames: expectedFrames))
        let stream = try await source.start()
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.channel, .microphone)
        XCTAssertEqual(
            first?.sampleRate,
            BenchSyntheticCapturePolicy.sampleRate)
        XCTAssertEqual(
            first?.samples.count,
            BenchSyntheticCapturePolicy.chunkFrames)
        XCTAssertEqual(first?.timestamp, 0)
        XCTAssertTrue(first?.samples.contains(where: { $0 != 0 }) == true)

        source.setMuted(true)
        let second = try await iterator.next()
        XCTAssertTrue(second?.samples.allSatisfy { $0 == 0 } == true)

        await source.stop()
        var observedFrames = Int64(first?.samples.count ?? 0)
            + Int64(second?.samples.count ?? 0)
        while let chunk = try await iterator.next() {
            observedFrames += Int64(chunk.samples.count)
        }
        XCTAssertEqual(observedFrames, expectedFrames)
    }

    func testSyntheticCaptureRejectsAnInvalidFramePlanWithoutCrashing() {
        XCTAssertEqual(
            BenchSyntheticCapturePolicy.expectedFrames(durationSeconds: 60),
            960_000)
        XCTAssertTrue(BenchSyntheticCapturePolicy.hasExactFrames(
            [.microphone: 960_000, .system: 960_000],
            expectedFrames: 960_000))
        XCTAssertFalse(BenchSyntheticCapturePolicy.hasExactFrames(
            [.microphone: 960_000, .system: 958_400],
            expectedFrames: 960_000))
        XCTAssertNil(BenchSyntheticCapturePolicy.expectedFrames(
            durationSeconds: 29))
        XCTAssertNil(BenchSyntheticCapturePolicy.expectedFrames(
            durationSeconds: 601))
        XCTAssertNil(BenchSyntheticAudioCaptureSource(
            channel: .system,
            expectedFrames: 0))
        XCTAssertNil(BenchSyntheticAudioCaptureSource(
            channel: .system,
            expectedFrames: Int64(
                BenchSyntheticCapturePolicy.chunkFrames + 1)))
    }

    func testSyntheticCapturePacingUsesAbsoluteFrameDeadlines() {
        XCTAssertEqual(
            BenchSyntheticCapturePolicy.deadlineOffset(afterFrames: 0),
            .zero)
        XCTAssertEqual(
            BenchSyntheticCapturePolicy.deadlineOffset(afterFrames: 1_600),
            .milliseconds(100))
        XCTAssertEqual(
            BenchSyntheticCapturePolicy.deadlineOffset(afterFrames: 960_000),
            .seconds(60))
        XCTAssertNil(BenchSyntheticCapturePolicy.deadlineOffset(afterFrames: -1))
        XCTAssertNil(BenchSyntheticCapturePolicy.deadlineOffset(
            afterFrames: 9_600_001))
    }

    func testLiveSpeechWarmupUsesExactPublicBoundedInput() {
        let chunks = BenchLiveSpeechResourceWarmup.fixtureChunks()
        XCTAssertEqual(BenchLiveSpeechResourceWarmup.timeoutSeconds, 60)
        XCTAssertEqual(chunks.count, 20)
        XCTAssertEqual(
            chunks.reduce(0) { $0 + $1.samples.count },
            32_000)
        XCTAssertTrue(chunks.allSatisfy {
            $0.channel == .microphone
                && $0.sampleRate == BenchSyntheticCapturePolicy.sampleRate
                && $0.samples.contains(where: { $0 != 0 })
        })
        XCTAssertEqual(chunks.first?.timestamp, 0)
        XCTAssertEqual(chunks.last?.timestamp ?? 0, 1.9, accuracy: 0.000_001)
        XCTAssertEqual(
            BenchLiveSpeechResourceWarmupError.runtimeUnavailable
                .errorDescription,
            "live transcription warmup requires a resident speech runtime")
        XCTAssertEqual(
            BenchLiveSpeechResourceWarmupError.timedOut(60).errorDescription,
            "live transcription warmup exceeded 60 seconds")
    }

    func testResourceProcessWatchdogRequiresOneBoundedIsolatedAdmission() throws {
        XCTAssertNil(try BenchResourceProcessWatchdog.timeoutSeconds(
            arguments: ["Portavoz", "-use-temp-store"]))
        XCTAssertEqual(
            try BenchResourceProcessWatchdog.timeoutSeconds(arguments: [
                "Portavoz",
                "-use-temp-store",
                "--bench-record", "60",
                "--bench-resource-process-timeout", "1200",
            ]),
            1_200)
        for arguments in [
            [
                "Portavoz", "--bench-record", "60",
                "--bench-resource-process-timeout", "1200",
            ],
            [
                "Portavoz", "-use-temp-store",
                "--bench-resource-process-timeout", "1200",
            ],
            [
                "Portavoz", "-use-temp-store", "--bench-record", "60",
                "--bench-resource-process-timeout", "59",
            ],
            [
                "Portavoz", "-use-temp-store", "--bench-record", "60",
                "--bench-resource-process-timeout", "7201",
            ],
            [
                "Portavoz", "-use-temp-store", "--bench-record", "60",
                "--bench-resource-process-timeout", "1200",
                "--bench-resource-process-timeout", "1200",
            ],
        ] {
            XCTAssertThrowsError(try BenchResourceProcessWatchdog
                .timeoutSeconds(arguments: arguments))
        }
    }

    func testResourceBenchmarksOwnTheirProcessStartup() {
        XCTAssertTrue(BenchMode.runsIsolatedBenchmark(
            arguments: ["Portavoz", "--bench-resource-launch-probe", "/tmp/ready"]))
        XCTAssertTrue(BenchMode.runsIsolatedBenchmark(
            arguments: ["Portavoz", "--bench-record", "30"]))
        XCTAssertTrue(BenchMode.runsIsolatedBenchmark(
            arguments: [
                "Portavoz", "--bench-resource-prepare-refine", "/tmp/ready",
            ]))
        XCTAssertTrue(BenchMode.runsIsolatedBenchmark(
            arguments: ["Portavoz", "--bench-resource-refine", "fixture.aiff"]))
        XCTAssertTrue(BenchMode.runsIsolatedBenchmark(
            arguments: ["Portavoz", "--bench-resource-summary"]))
        XCTAssertTrue(BenchMode.runsIsolatedBenchmark(
            arguments: ["Portavoz", "--bench-resource-ask"]))
        XCTAssertTrue(BenchMode.runsIsolatedBenchmark(
            arguments: ["Portavoz", "--bench-resource-indexing"]))
        XCTAssertTrue(BenchMode.runsIsolatedBenchmark(
            arguments: ["Portavoz", "--bench-graph-queries"]))
        XCTAssertFalse(BenchMode.runsIsolatedBenchmark(
            arguments: ["Portavoz", "-use-temp-store", "-seed-demo"]))
    }

    func testIsolatedBenchmarksSuppressOpportunisticModelVerification() {
        for arguments in [
            ["Portavoz", "--bench-resource-launch-probe", "/tmp/ready"],
            ["Portavoz", "--bench-record", "30"],
            ["Portavoz", "--bench-resource-prepare-refine", "/tmp/ready"],
            ["Portavoz", "--bench-resource-refine", "fixture.aiff"],
            ["Portavoz", "--bench-resource-summary"],
            ["Portavoz", "--bench-resource-ask"],
            ["Portavoz", "--bench-resource-indexing"],
            ["Portavoz", "--bench-graph-queries"],
        ] {
            XCTAssertFalse(AppInitialModelReadinessPolicy.schedulesRefresh(
                arguments: arguments))
        }
        XCTAssertTrue(AppInitialModelReadinessPolicy.schedulesRefresh(
            arguments: ["Portavoz", "-use-temp-store", "-seed-demo"]))
    }

    func testResourceLaunchProbeRequiresFreshAbsoluteOwnerOnlyOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BenchResourceLaunchProbe-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("ready")

        XCTAssertNil(try BenchResourceLaunchProbe.requested(arguments: [
            "Portavoz", "-use-temp-store",
        ]))
        XCTAssertThrowsError(try BenchResourceLaunchProbe.requested(arguments: [
            "Portavoz", "-use-temp-store", "--bench-resource-launch-probe",
        ])) {
            XCTAssertEqual(
                $0 as? BenchResourceLaunchProbeError,
                .missingOutput)
        }
        XCTAssertThrowsError(try BenchResourceLaunchProbe.requested(arguments: [
            "Portavoz", "--bench-resource-launch-probe", output.path,
        ])) {
            XCTAssertEqual(
                $0 as? BenchResourceLaunchProbeError,
                .temporaryStoreRequired)
        }
        XCTAssertThrowsError(try BenchResourceLaunchProbe.requested(arguments: [
            "Portavoz", "-use-temp-store",
            "--bench-resource-launch-probe", "relative/ready",
        ])) {
            XCTAssertEqual(
                $0 as? BenchResourceLaunchProbeError,
                .absoluteOutputRequired)
        }
        XCTAssertThrowsError(try BenchResourceLaunchProbe.requested(arguments: [
            "Portavoz", "-use-temp-store",
            "--bench-resource-launch-probe", output.path,
            "--bench-resource-launch-probe", output.path,
        ])) {
            XCTAssertEqual(
                $0 as? BenchResourceLaunchProbeError,
                .duplicateOption)
        }

        let request = try XCTUnwrap(BenchResourceLaunchProbe.requested(arguments: [
            "Portavoz", "-use-temp-store",
            "--bench-resource-launch-probe", output.path,
        ]))
        XCTAssertEqual(request, output.standardizedFileURL)
        try BenchResourceLaunchProbe.writeMarker(to: request)

        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            BenchResourceLaunchProbe.marker)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: output.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
        XCTAssertThrowsError(try BenchResourceLaunchProbe.writeMarker(to: output)) {
            XCTAssertEqual(
                $0 as? BenchResourceLaunchProbeError,
                .outputAlreadyExists)
        }

        let refineOutput = root.appendingPathComponent("refine-ready")
        try BenchResourceLaunchProbe.writeMarker(
            to: refineOutput,
            marker: .refineRuntimePrepared)
        XCTAssertEqual(
            try String(contentsOf: refineOutput, encoding: .utf8),
            BenchResourceLaunchProbe.Marker.refineRuntimePrepared.rawValue)
        let refineAttributes = try FileManager.default.attributesOfItem(
            atPath: refineOutput.path)
        XCTAssertEqual(
            (refineAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
    }

    func testRefineResourceConfigurationBoundsTimeout() throws {
        let configuration = try XCTUnwrap(
            BenchRefineResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-refine", "/tmp/refine.aiff",
                "--bench-resource-timeout", "1200",
            ]))
        XCTAssertEqual(configuration.fixtureURL.path, "/tmp/refine.aiff")
        XCTAssertEqual(configuration.timeoutSeconds, 1_200)

        XCTAssertThrowsError(
            try BenchRefineResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-refine", "/tmp/refine.aiff",
                "--bench-resource-timeout", "59",
            ])
        ) {
            XCTAssertEqual(
                $0 as? BenchRefineResourceError,
                .invalidTimeout)
        }

        let preparation = try XCTUnwrap(
            BenchRefinePreparationConfiguration.requested(arguments: [
                "Portavoz", "-use-temp-store",
                "--bench-resource-prepare-refine", "/tmp/refine-ready",
                "--bench-resource-timeout", "1200",
            ]))
        XCTAssertEqual(preparation.outputURL.path, "/tmp/refine-ready")
        XCTAssertEqual(preparation.timeoutSeconds, 1_200)
        XCTAssertThrowsError(
            try BenchRefinePreparationConfiguration.requested(arguments: [
                "Portavoz", "-use-temp-store",
                "--bench-resource-prepare-refine", "relative/refine-ready",
            ])) {
            XCTAssertEqual(
                $0 as? BenchRefineResourcePreparationError,
                .absoluteOutputRequired)
        }
        XCTAssertThrowsError(
            try BenchRefinePreparationConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-prepare-refine", "/tmp/refine-ready",
            ])) {
            XCTAssertEqual(
                $0 as? BenchRefineResourcePreparationError,
                .temporaryStoreRequired)
        }
    }

    func testSummaryResourceConfigurationBoundsTimeout() throws {
        let configuration = try XCTUnwrap(
            BenchSummaryResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-summary",
                "--bench-resource-timeout", "600",
            ]))
        XCTAssertEqual(configuration.timeoutSeconds, 600)

        XCTAssertThrowsError(
            try BenchSummaryResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-summary",
                "--bench-resource-timeout", "3601",
            ])
        ) {
            XCTAssertEqual(
                $0 as? BenchSummaryResourceError,
                .invalidTimeout)
        }
    }

    func testAskResourceConfigurationBoundsTimeout() throws {
        let configuration = try XCTUnwrap(
            BenchAskResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-ask",
                "--bench-resource-timeout", "480",
            ]))
        XCTAssertEqual(configuration.timeoutSeconds, 480)
        XCTAssertEqual(configuration.iterations, 1)

        let repeated = try XCTUnwrap(
            BenchAskResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-ask",
                "--bench-resource-iterations", "10",
            ]))
        XCTAssertEqual(repeated.iterations, 10)

        XCTAssertThrowsError(
            try BenchAskResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-ask",
                "--bench-resource-timeout", "59",
            ])
        ) {
            XCTAssertEqual(
                $0 as? BenchAskResourceError,
                .invalidTimeout)
        }
        XCTAssertThrowsError(
            try BenchAskResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-ask",
                "--bench-resource-iterations", "11",
            ])
        ) {
            XCTAssertEqual(
                $0 as? BenchAskResourceError,
                .invalidIterations)
        }
        XCTAssertThrowsError(
            try BenchAskResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-ask",
                "--bench-resource-iterations", "10",
                "--bench-resource-iterations", "10",
            ])
        ) {
            XCTAssertEqual(
                $0 as? BenchAskResourceError,
                .invalidIterations)
        }
    }

    func testIndexingResourceConfigurationBoundsTimeout() throws {
        let configuration = try XCTUnwrap(
            BenchIndexingResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-indexing",
                "--bench-resource-timeout", "360",
            ]))
        XCTAssertEqual(configuration.timeoutSeconds, 360)
        XCTAssertEqual(configuration.iterations, 1)

        let repeated = try XCTUnwrap(
            BenchIndexingResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-indexing",
                "--bench-resource-iterations", "10",
            ]))
        XCTAssertEqual(repeated.iterations, 10)

        XCTAssertThrowsError(
            try BenchIndexingResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-indexing",
                "--bench-resource-timeout", "3_601",
            ])
        ) {
            XCTAssertEqual(
                $0 as? BenchIndexingResourceError,
                .invalidTimeout)
        }
        XCTAssertThrowsError(
            try BenchIndexingResourceConfiguration.requested(arguments: [
                "Portavoz",
                "--bench-resource-indexing",
                "--bench-resource-iterations", "11",
            ])
        ) {
            XCTAssertEqual(
                $0 as? BenchIndexingResourceError,
                .invalidIterations)
        }
    }

    @MainActor
    func testIndexingResourceWarmupExecutesExactCorpusWithoutPreparingRuntime()
        async throws
    {
        let embedder = IndexingWarmupEmbedder()
        let runtime = IndexingWarmupRuntime(embedder: embedder)

        try await BenchMode.prepareIndexingResourceWarmup(
            runtime: runtime,
            telemetry: .disabled,
            timeoutSeconds: 30)

        let requests = await runtime.requests()
        let batchSizes = await embedder.observedBatchSizes()
        XCTAssertEqual(requests.prepare, [])
        XCTAssertEqual(requests.borrow, [false])
        XCTAssertEqual(batchSizes, [256, 256, 256, 256])
    }

    @MainActor
    func testIndexingResourceWarmupFailsClosedBeforeBorrowWithoutAssets() async {
        let embedder = IndexingWarmupEmbedder()
        let runtime = IndexingWarmupRuntime(
            assetsAvailable: false,
            embedder: embedder)

        do {
            try await BenchMode.prepareIndexingResourceWarmup(
                runtime: runtime,
                telemetry: .disabled,
                timeoutSeconds: 30)
            XCTFail("Expected missing embedding assets to fail the warmup")
        } catch {
            XCTAssertEqual(
                error as? BenchIndexingResourceError,
                .assetsNotReady)
        }

        let requests = await runtime.requests()
        let batchSizes = await embedder.observedBatchSizes()
        XCTAssertEqual(requests.prepare, [])
        XCTAssertEqual(requests.borrow, [])
        XCTAssertEqual(batchSizes, [])
    }

    @MainActor
    func testTimedResourceOperationReturnsFirstSuccessfulValue() async throws {
        let value = try await BenchResourceTimedOperation.run(
            timeout: .seconds(1)
        ) {
            42
        }

        XCTAssertEqual(value, 42)
    }

    @MainActor
    func testTimedResourceOperationPreservesFailureAsContentFreeText() async {
        do {
            let _: Int = try await BenchResourceTimedOperation.run(
                timeout: .seconds(1)
            ) {
                throw BenchSummaryResourceError.modelsNotReady
            }
            XCTFail("Expected the operation to fail")
        } catch {
            XCTAssertEqual(
                error as? BenchResourceTimedOperationError,
                .operationFailed(
                    BenchSummaryResourceError.modelsNotReady.localizedDescription))
        }
    }

    @MainActor
    func testTimedResourceOperationDoesNotAwaitCancelledWork() async {
        let startedAt = ContinuousClock.now
        do {
            let _: Int = try await BenchResourceTimedOperation.run(
                timeout: .milliseconds(20)
            ) {
                try await Task.sleep(for: .seconds(5))
                return 42
            }
            XCTFail("Expected the operation to time out")
        } catch {
            XCTAssertEqual(
                error as? BenchResourceTimedOperationError,
                .timedOut)
        }
        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .seconds(1))
    }

    func testHostReadinessRequiresTwoConsecutiveNominalObservations() async throws {
        let states = ThermalStateSequence([
            .fair,
            .nominal,
            .fair,
            .nominal,
            .nominal,
        ])

        try await ResourceProbeHostReadiness.waitUntilNominal(
            maximumObservations: 5,
            pollInterval: .zero,
            thermalState: states.next,
            sleep: { _ in })

        XCTAssertEqual(states.observationCount, 5)
    }

    func testHostReadinessFailsClosedWhenThermalPressurePersists() async {
        let states = ThermalStateSequence([
            .fair,
            .serious,
            .critical,
        ])

        do {
            try await ResourceProbeHostReadiness.waitUntilNominal(
                maximumObservations: 3,
                pollInterval: .zero,
                thermalState: states.next,
                sleep: { _ in })
            XCTFail("Expected thermal readiness to time out")
        } catch {
            XCTAssertEqual(
                error as? ResourceProbeHostReadinessError,
                .thermalPressureDidNotSettle)
        }
    }

    @MainActor
    func testSingleScenarioProbeWritesOneExactSample() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BenchResourceScenarioProbe-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let probe = try BenchResourceScenarioProbe(
            arguments: [
                "Portavoz",
                "--bench-resource-output", output.path,
                "--bench-resource-run", "3",
            ],
            readiness: {})

        let value = try await probe.measure(scenario: "refine") {
            try await Task.sleep(for: .milliseconds(10))
            return 42
        }

        XCTAssertEqual(value, 42)
        let sampleURL = output.appendingPathComponent("refine-3.json")
        let sample = try JSONDecoder().decode(
            ResourceProbeSample.self,
            from: Data(contentsOf: sampleURL))
        XCTAssertEqual(sample.run, 3)
        XCTAssertGreaterThan(sample.wallDurationMilliseconds, 0)
        XCTAssertTrue(sample.workloads.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: sampleURL.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
    }

    @MainActor
    func testSingleScenarioProbeFailurePublishesNoPartialSample() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BenchResourceScenarioProbeFailure-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let probe = try BenchResourceScenarioProbe(
            arguments: [
                "Portavoz",
                "--bench-resource-output", output.path,
                "--bench-resource-run", "4",
            ],
            readiness: {})

        do {
            let _: Int = try await probe.measure(scenario: "refine") {
                throw BenchRefineResourceError.operationFailed("expected")
            }
            XCTFail("Expected the measured operation to fail")
        } catch {
            XCTAssertEqual(
                error as? BenchRefineResourceError,
                .operationFailed("expected"))
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("refine-4.json").path))
    }

    func testBenchResourceArgumentsBoundIdleDuration() throws {
        let output = FileManager.default.temporaryDirectory.path
        let probes = try XCTUnwrap(BenchRecordResourceProbes.requested(
            arguments: [
                "Portavoz", "--bench-resource-output", output,
                "--bench-resource-run", "4",
                "--bench-resource-idle-duration", "45",
            ]))
        XCTAssertEqual(probes.idleDurationSeconds, 45)

        XCTAssertThrowsError(try BenchRecordResourceProbes.requested(
            arguments: [
                "Portavoz", "--bench-resource-output", output,
                "--bench-resource-run", "4",
                "--bench-resource-idle-duration", "9",
            ])) {
            XCTAssertEqual(
                $0 as? BenchRecordResourceProbeError,
                .invalidIdleDuration)
        }
    }

    func testConcurrentRecordingProbeBoundsTimeout() throws {
        let output = FileManager.default.temporaryDirectory.path
        let probe = try XCTUnwrap(
            BenchConcurrentRecordingResourceProbe
                .requested(arguments: [
                    "Portavoz",
                    "--bench-resource-recording-indexing",
                    "--bench-resource-output", output,
                    "--bench-resource-run", "4",
                    "--bench-resource-timeout", "480",
                ]))
        XCTAssertEqual(probe.timeoutSeconds, 480)

        XCTAssertThrowsError(
            try BenchConcurrentRecordingResourceProbe
                .requested(arguments: [
                    "Portavoz",
                    "--bench-resource-recording-indexing",
                    "--bench-resource-output", output,
                    "--bench-resource-run", "4",
                    "--bench-resource-timeout", "59",
                ])
        ) {
            XCTAssertEqual(
                $0 as? BenchConcurrentProbeError,
                .invalidTimeout)
        }
    }

    func testConcurrentRecordingProbeRejectsCompetingScenarios() {
        XCTAssertThrowsError(
            try BenchConcurrentRecordingResourceProbe.requested(arguments: [
                "Portavoz",
                "--bench-resource-recording-indexing",
                "--bench-resource-recording-batch", "/tmp/fixture.aiff",
            ])
        ) {
            XCTAssertEqual(
                $0 as? BenchConcurrentProbeError,
                .conflictingScenarios)
        }
    }

    func testRecordingBatchConfigurationRequiresExistingFixture() {
        XCTAssertThrowsError(
            try BenchBatchResourceConfiguration.requested(
                arguments: [
                    "Portavoz",
                    "--bench-resource-recording-batch",
                    "/tmp/portavoz-missing-\(UUID().uuidString).aiff",
                ])
        ) {
            XCTAssertEqual(
                $0 as? BenchBatchResourceError,
                .missingFixture)
        }
    }

    func testRecordingIndexingProbeFreezesBeforeStopAndRetainsLiveFinish() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BenchRecordingIndexingProbe-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let probe = try XCTUnwrap(
            BenchConcurrentRecordingResourceProbe
                .requested(arguments: [
                    "Portavoz",
                    "--bench-resource-recording-indexing",
                    "--bench-resource-output", output.path,
                    "--bench-resource-run", "7",
                ]))
        let telemetry = AppResourceWorkloadTelemetry.shared.telemetry

        try probe.begin()
        defer { probe.cancel() }
        let capture = telemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .recordingCritical,
            kind: .audioCapture,
            operation: .execute))
        telemetry.finish(capture, outcome: .completed)
        let live = telemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .liveInteractive,
            kind: .liveTranscription,
            operation: .execute))
        let indexing = telemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .maintenance,
            kind: .searchIndex,
            operation: .execute))
        telemetry.finish(indexing, outcome: .completed)
        try probe.freezeBeforeStop()
        telemetry.finish(live, outcome: .completed)
        let stopOnly = telemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .recordingCritical,
            kind: .audioCapture,
            operation: .release))
        telemetry.finish(stopOnly, outcome: .completed)
        try probe.finishAfterStopAndWrite()

        let sample = try JSONDecoder().decode(
            ResourceProbeSample.self,
            from: Data(contentsOf: output.appendingPathComponent(
                "recording-indexing-7.json")))
        XCTAssertEqual(sample.run, 7)
        XCTAssertEqual(
            Set(sample.workloads.map {
                "\($0.workloadClass)/\($0.kind)/\($0.operation)"
            }),
            Set([
                "recordingCritical/audioCapture/execute",
                "liveInteractive/liveTranscription/execute",
                "maintenance/searchIndex/execute",
            ]))
    }

    func testRecordingBatchProbePublishesExactConcurrentWorkloads() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BenchRecordingBatchProbe-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let probe = try XCTUnwrap(
            BenchConcurrentRecordingResourceProbe.requested(arguments: [
                "Portavoz",
                "--bench-resource-recording-batch", "/tmp/fixture.aiff",
                "--bench-resource-output", output.path,
                "--bench-resource-run", "8",
            ]))
        let telemetry = AppResourceWorkloadTelemetry.shared.telemetry

        try probe.begin()
        defer { probe.cancel() }
        for descriptor in [
            ResourceWorkloadDescriptor(
                workloadClass: .recordingCritical,
                kind: .audioCapture,
                operation: .execute),
            ResourceWorkloadDescriptor(
                workloadClass: .liveInteractive,
                kind: .liveTranscription,
                operation: .execute),
            ResourceWorkloadDescriptor(
                workloadClass: .postCapture,
                kind: .qualityTranscription,
                operation: .execute),
        ] {
            let span = telemetry.begin(descriptor)
            telemetry.finish(span, outcome: .completed)
        }
        try probe.freezeBeforeStop()
        try probe.finishAfterStopAndWrite()

        let sample = try JSONDecoder().decode(
            ResourceProbeSample.self,
            from: Data(contentsOf: output.appendingPathComponent(
                "recording-batch-8.json")))
        XCTAssertEqual(sample.run, 8)
        XCTAssertEqual(
            Set(sample.workloads.map {
                "\($0.workloadClass)/\($0.kind)/\($0.operation)"
            }),
            Set([
                "recordingCritical/audioCapture/execute",
                "liveInteractive/liveTranscription/execute",
                "postCapture/qualityTranscription/execute",
            ]))
    }

    func testProbeAggregatesProcessMetricsAndNearestRankWorkloads() throws {
        let usage = UsageSequence([
            makeUsage(
                cpu: 1_000,
                footprint: 500,
                energy: 100,
                read: 200,
                written: 300,
                disk: 10_000,
                thermal: .nominal),
            makeUsage(
                cpu: 2_000,
                footprint: 700,
                energy: 160,
                read: 240,
                written: 390,
                disk: 9_000,
                thermal: .serious,
                lowPower: true),
        ])
        let uptime = UptimeSequence(milliseconds: [
            0, 10, 20, 30, 50, 60, 90, 100,
        ])
        let probe = try ResourceRunProbe(
            run: 3,
            usageProvider: usage.next,
            uptimeProvider: uptime.next)
        let descriptor = ResourceWorkloadDescriptor(
            workloadClass: .liveInteractive,
            kind: .liveTranscription,
            operation: .execute)
        for _ in 0..<3 {
            let span = ResourceWorkloadSpan(descriptor: descriptor)
            probe.receive(.started(span))
            probe.receive(.finished(span, outcome: .completed))
        }

        try probe.stopMeasurement()
        let sample = try probe.makeSample()

        XCTAssertEqual(sample.run, 3)
        XCTAssertEqual(sample.wallDurationMilliseconds, 100, accuracy: 0.001)
        XCTAssertEqual(sample.peakPhysicalFootprintBytes, 700)
        XCTAssertEqual(sample.energyNanojoules, 60)
        XCTAssertEqual(sample.diskReadBytes, 40)
        XCTAssertEqual(sample.diskWrittenBytes, 90)
        XCTAssertEqual(sample.minimumAvailableDiskBytes, 9_000)
        XCTAssertEqual(sample.maximumThermalState, "serious")
        XCTAssertEqual(sample.powerSource, "ac")
        XCTAssertTrue(sample.lowPowerModeEnabled)
        XCTAssertEqual(sample.workloads.count, 1)
        XCTAssertEqual(sample.workloads[0].count, 3)
        XCTAssertEqual(
            sample.workloads[0].durationMilliseconds,
            ResourceProbeDurationSummary(
                p50: 20,
                p95: 30,
                maximum: 30))
    }

    func testMetricFreezeAllowsExistingSpanToDrainAndIgnoresStopWork() throws {
        let usage = UsageSequence([
            makeUsage(cpu: 1, footprint: 100),
            makeUsage(cpu: 2, footprint: 120),
        ])
        let uptime = UptimeSequence(milliseconds: [0, 10, 20, 30, 40, 50])
        let probe = try ResourceRunProbe(
            run: 1,
            usageProvider: usage.next,
            uptimeProvider: uptime.next)
        let live = ResourceWorkloadSpan(descriptor: .init(
            workloadClass: .liveInteractive,
            kind: .liveTranscription,
            operation: .execute))
        probe.receive(.started(live))
        try probe.stopMeasurement()

        let stop = ResourceWorkloadSpan(descriptor: .init(
            workloadClass: .recordingCritical,
            kind: .audioCapture,
            operation: .execute))
        probe.receive(.started(stop))
        probe.receive(.finished(stop, outcome: .completed))
        probe.receive(.finished(live, outcome: .cancelled))

        let workloads = try probe.makeSample().workloads
        XCTAssertEqual(workloads.count, 1)
        XCTAssertEqual(workloads[0].kind, "liveTranscription")
        XCTAssertEqual(workloads[0].outcome, "cancelled")
        XCTAssertEqual(workloads[0].durationMilliseconds.maximum, 40)
    }

    func testPowerSourceChangeFailsClosed() throws {
        let usage = UsageSequence([
            makeUsage(cpu: 1, footprint: 100, power: .ac),
            makeUsage(cpu: 2, footprint: 100, power: .battery),
        ])
        let uptime = UptimeSequence(milliseconds: [0, 10])
        let probe = try ResourceRunProbe(
            run: 1,
            usageProvider: usage.next,
            uptimeProvider: uptime.next)

        try probe.stopMeasurement()

        XCTAssertThrowsError(try probe.makeSample()) {
            XCTAssertEqual(
                $0 as? ResourceRunProbeError,
                .powerSourceChanged)
        }
    }

    func testSampleExportIsOwnerOnlyAndNeverOverwritesEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = UsageSequence([
            makeUsage(cpu: 1, footprint: 100),
            makeUsage(cpu: 2, footprint: 100),
        ])
        let uptime = UptimeSequence(milliseconds: [0, 10])
        let probe = try ResourceRunProbe(
            run: 1,
            usageProvider: usage.next,
            uptimeProvider: uptime.next)
        try probe.stopMeasurement()
        let output = root.appendingPathComponent("recording-1.json")

        try probe.writeSample(to: output)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: output.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output))
                as? [String: Any])
        XCTAssertEqual(
            Set(document.keys),
            Set([
                "run", "wallDurationMilliseconds", "cpuTimeMilliseconds",
                "peakPhysicalFootprintBytes", "energyNanojoules",
                "diskReadBytes", "diskWrittenBytes",
                "minimumAvailableDiskBytes", "maximumThermalState",
                "powerSource", "lowPowerModeEnabled", "workloads",
            ]))
        XCTAssertThrowsError(try probe.writeSample(to: output)) {
            XCTAssertEqual(
                $0 as? ResourceRunProbeError,
                .outputAlreadyExists)
        }
    }

    func testAppTelemetryObserverReplaysActiveSpanAndHasExplicitLifetime() {
        let recorder = ResourceProbeEventRecorder()
        let adapter = AppResourceWorkloadTelemetry.shared
        let telemetry = adapter.telemetry
        let descriptor = ResourceWorkloadDescriptor(
            workloadClass: .recordingCritical,
            kind: .audioCapture,
            operation: .execute)
        let first = telemetry.begin(descriptor)
        let observer = adapter.addObserver(
            replayingActive: true,
            recorder.receive)
        telemetry.finish(first, outcome: .completed)
        adapter.removeObserver(observer)
        let second = telemetry.begin(descriptor)
        telemetry.finish(second, outcome: .completed)

        XCTAssertEqual(recorder.count, 2)
    }

    private func makeUsage(
        cpu: UInt64,
        footprint: UInt64,
        energy: UInt64 = 0,
        read: UInt64 = 0,
        written: UInt64 = 0,
        disk: UInt64 = 1_000,
        thermal: ResourceProbeThermalState = .nominal,
        power: ResourceProbePowerSource = .ac,
        lowPower: Bool = false
    ) -> ResourceProbeUsage {
        ResourceProbeUsage(
            cpuAbsoluteTime: cpu,
            physicalFootprintBytes: footprint,
            energyNanojoules: energy,
            diskReadBytes: read,
            diskWrittenBytes: written,
            availableDiskBytes: disk,
            thermalState: thermal,
            powerSource: power,
            lowPowerModeEnabled: lowPower)
    }
}

private final class UsageSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ResourceProbeUsage]

    init(_ values: [ResourceProbeUsage]) {
        self.values = values
    }

    func next() throws -> ResourceProbeUsage {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else {
            throw ResourceRunProbeError.processUsageUnavailable
        }
        return values.removeFirst()
    }
}

private final class UptimeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(milliseconds: [UInt64]) {
        values = milliseconds.map { $0 * 1_000_000 }
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}

private final class ThermalStateSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ResourceProbeThermalState]
    private(set) var observationCount = 0

    init(_ values: [ResourceProbeThermalState]) {
        self.values = values
    }

    func next() -> ResourceProbeThermalState {
        lock.lock()
        defer { lock.unlock() }
        observationCount += 1
        return values.removeFirst()
    }
}

private final class ResourceProbeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func receive(_ event: ResourceWorkloadEvent) {
        _ = event
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private actor IndexingWarmupRuntime: SemanticEmbeddingRuntimeClient {
    private let assetsAvailable: Bool
    private let embedder: IndexingWarmupEmbedder
    private var prepareRequests: [Bool] = []
    private var borrowRequests: [Bool] = []

    init(
        assetsAvailable: Bool = true,
        embedder: IndexingWarmupEmbedder
    ) {
        self.assetsAvailable = assetsAvailable
        self.embedder = embedder
    }

    var hasAvailableAssets: Bool {
        get async { assetsAvailable }
    }

    func semanticEmbeddingProfile() -> SemanticEmbeddingProfile? {
        semanticTestProfile()
    }

    func prepare(allowAssetDownload: Bool) {
        prepareRequests.append(allowAssetDownload)
    }

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload: Bool,
        operation: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        borrowRequests.append(allowAssetDownload)
        return try await operation(embedder)
    }

    func requests() -> (prepare: [Bool], borrow: [Bool]) {
        (prepareRequests, borrowRequests)
    }
}

private actor IndexingWarmupEmbedder: SemanticTextEmbedding {
    private var batchSizes: [Int] = []

    func semanticEmbeddingProfile() -> SemanticEmbeddingProfile {
        semanticTestProfile()
    }

    func vectors(for texts: [String]) -> [[Float]] {
        batchSizes.append(texts.count)
        return texts.map { _ in [1, 0] }
    }

    func observedBatchSizes() -> [Int] {
        batchSizes
    }
}
