import PortavozCore
import XCTest

final class ResourceGovernorPolicyTests: XCTestCase {
    private let policy = ResourceGovernorPolicy()

    func testTaxonomyIsClosedAndStable() {
        XCTAssertEqual(
            ResourceCaptureState.allCases.map(\.rawValue),
            ["inactive", "starting", "active", "stopping"])
        XCTAssertEqual(
            ResourceCaptureSourceHealth.allCases.map(\.rawValue),
            ["healthy", "degraded", "failed"])
        XCTAssertEqual(
            ResourceMemoryTier.allCases.map(\.rawValue),
            ["unknown", "constrained", "standard", "large"])
        XCTAssertEqual(
            ResourceDiskState.allCases.map(\.rawValue),
            ["unknown", "sufficient", "low", "critical"])
        XCTAssertEqual(
            ResourceMemoryPressure.allCases.map(\.rawValue),
            ["nominal", "warning", "critical"])
        XCTAssertEqual(
            ResourceThermalState.allCases.map(\.rawValue),
            ["nominal", "fair", "serious", "critical"])
        XCTAssertEqual(
            ResourcePowerSource.allCases.map(\.rawValue),
            ["unknown", "external", "battery"])
        XCTAssertEqual(
            ResourceDurableBacklog.allCases.map(\.rawValue),
            ["empty", "present", "saturated"])
        XCTAssertEqual(
            ResourceGovernorEvaluationPhase.allCases.map(\.rawValue),
            ["admission", "checkpoint"])
        XCTAssertEqual(
            ResourceDeferralCondition.allCases.map(\.rawValue),
            [
                "captureStops", "hostRecovers", "storageAvailable",
                "externalPower", "lowPowerModeDisabled"
            ])
        XCTAssertEqual(
            ResourceRecoveryAction.allCases.map(\.rawValue),
            ["freeDiskSpace", "restoreAudioInput", "waitForSystemToRecover"])
        XCTAssertEqual(
            ResourceModelFamily.allCases.map(\.rawValue),
            [
                "liveSpeech", "qualitySpeech", "speakerDiarization",
                "languageIntelligence", "semanticEmbedding"
            ])
    }

    func testEveryWorkloadClassAndCaptureStateMatchesAdmissionMatrix() {
        for workloadClass in ResourceWorkloadClass.allCases {
            for captureState in ResourceCaptureState.allCases {
                let request = request(workloadClass: workloadClass)
                let snapshot = snapshot(captureState: captureState)
                let expected: ResourceAdmissionDisposition
                switch (workloadClass, captureState) {
                case (.userInitiated, .starting),
                     (.userInitiated, .active),
                     (.userInitiated, .stopping):
                    expected = .admitWithReducedConcurrency
                case (.postCapture, .starting),
                     (.postCapture, .active),
                     (.postCapture, .stopping),
                     (.maintenance, .starting),
                     (.maintenance, .active),
                     (.maintenance, .stopping):
                    expected = .defer(until: .captureStops)
                default:
                    expected = .admitNow
                }

                XCTAssertEqual(
                    policy.evaluate(
                        request: request,
                        snapshot: snapshot
                    ).disposition,
                    expected,
                    "\(workloadClass.rawValue) / \(captureState.rawValue)")
            }
        }
    }

    func testMeasuredFootprintDoesNotInventANumericBudget() {
        let request = request(
            workloadClass: .userInitiated,
            kind: .languageInference)
        let small = snapshot(
            residentModels: [resident(.qualitySpeech, footprint: 1)])
        let large = snapshot(
            residentModels: [resident(.qualitySpeech, footprint: UInt64.max)])

        XCTAssertEqual(
            policy.evaluate(request: request, snapshot: small),
            policy.evaluate(request: request, snapshot: large))
    }

    func testActiveRecordingCriticalWorkIsNeverDeniedUnderPressure() {
        let request = request(
            workloadClass: .recordingCritical,
            kind: .audioCapture)
        let snapshot = snapshot(
            captureState: .active,
            diskState: .critical,
            memoryPressure: .critical,
            thermalState: .critical,
            residentModels: [
                resident(.qualitySpeech),
                resident(.languageIntelligence)
            ])

        XCTAssertEqual(
            policy.evaluate(request: request, snapshot: snapshot),
            ResourceGovernorDecision(
                disposition: .admitNow,
                evictIdleModels: [.qualitySpeech, .languageIntelligence]))
    }

    func testCapturePreflightRejectsFailedInputBeforeCriticalDisk() {
        let request = request(
            workloadClass: .recordingCritical,
            kind: .audioCapture)
        let snapshot = snapshot(
            sourceHealth: .failed,
            diskState: .critical)

        XCTAssertEqual(
            policy.evaluate(request: request, snapshot: snapshot).disposition,
            .reject(recovery: .restoreAudioInput))
    }

    func testCapturePreflightRejectsCriticalDiskWithTypedRecovery() {
        let request = request(
            workloadClass: .recordingCritical,
            kind: .audioCapture)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(diskState: .critical)
            ).disposition,
            .reject(recovery: .freeDiskSpace))
    }

    func testPostCaptureAdmissionDefersWhileCaptureIsProtected() {
        let request = request(
            workloadClass: .postCapture,
            kind: .qualityTranscription)

        for state in [
            ResourceCaptureState.starting, .active, .stopping
        ] {
            XCTAssertEqual(
                policy.evaluate(
                    request: request,
                    snapshot: snapshot(captureState: state)
                ).disposition,
                .defer(until: .captureStops))
        }
    }

    func testMaintenanceCheckpointPausesWhileCaptureIsActive() {
        let request = request(
            workloadClass: .maintenance,
            kind: .searchIndex,
            phase: .checkpoint)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(captureState: .active)
            ).disposition,
            .pauseAfterCheckpoint)
    }

    func testMemoryGraphMaintenanceYieldsDuringCaptureAndResumesWhenIdle() {
        let admission = request(
            workloadClass: .maintenance,
            kind: .memoryGraph)
        let checkpoint = request(
            workloadClass: .maintenance,
            kind: .memoryGraph,
            phase: .checkpoint)

        XCTAssertEqual(
            policy.evaluate(
                request: admission,
                snapshot: snapshot(captureState: .active)
            ).disposition,
            .defer(until: .captureStops))
        XCTAssertEqual(
            policy.evaluate(
                request: checkpoint,
                snapshot: snapshot(captureState: .active)
            ).disposition,
            .pauseAfterCheckpoint)
        XCTAssertEqual(
            policy.evaluate(
                request: admission,
                snapshot: snapshot(captureState: .inactive)
            ).disposition,
            .admitNow)
    }

    func testLiveInteractiveWorkContinuesDuringHealthyCapture() {
        let request = request(
            workloadClass: .liveInteractive,
            kind: .liveTranscription)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(captureState: .active)
            ).disposition,
            .admitNow)
    }

    func testLiveInteractiveWorkReducesConcurrencyUnderCapturePressure() {
        let request = request(
            workloadClass: .liveInteractive,
            kind: .liveTranscription)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(
                    captureState: .active,
                    memoryPressure: .warning)
            ).disposition,
            .admitWithReducedConcurrency)
    }

    func testHeavyUserModelLoadDefersOnConstrainedMacDuringCapture() {
        let request = request(
            workloadClass: .userInitiated,
            kind: .languageInference,
            operation: .load)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(
                    captureState: .active,
                    memoryTier: .constrained)
            ).disposition,
            .defer(until: .captureStops))
    }

    func testNonModelUserActionUsesReducedConcurrencyDuringCapture() {
        let request = request(
            workloadClass: .userInitiated,
            kind: .mediaExport)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(captureState: .active)
            ).disposition,
            .admitWithReducedConcurrency)
    }

    func testCriticalStorageDefersDurableBackgroundWork() {
        let request = request(
            workloadClass: .maintenance,
            kind: .searchIndex)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(diskState: .critical)
            ).disposition,
            .defer(until: .storageAvailable))
    }

    func testCriticalStorageRejectsForegroundWriterWithRecovery() {
        let request = request(
            workloadClass: .userInitiated,
            kind: .mediaExport)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(
                    diskState: .critical,
                    hasForegroundAction: true)
            ).disposition,
            .reject(recovery: .freeDiskSpace))
    }

    func testCriticalStorageStillBlocksOptionalWriterDuringCapture() {
        let request = request(
            workloadClass: .userInitiated,
            kind: .mediaExport)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(
                    captureState: .active,
                    diskState: .critical,
                    hasForegroundAction: true)
            ).disposition,
            .reject(recovery: .freeDiskSpace))
    }

    func testSeverePressureDefersBackgroundAdmission() {
        let request = request(
            workloadClass: .postCapture,
            kind: .speakerDiarization)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(thermalState: .critical)
            ).disposition,
            .defer(until: .hostRecovers))
    }

    func testSeverePressureRejectsForegroundAdmissionWithRecovery() {
        let request = request(
            workloadClass: .userInitiated,
            kind: .languageInference)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(
                    memoryPressure: .critical,
                    hasForegroundAction: true)
            ).disposition,
            .reject(recovery: .waitForSystemToRecover))
    }

    func testSeverePressureKeepsLiveInteractiveWorkAdmitted() {
        let request = request(
            workloadClass: .liveInteractive,
            kind: .liveTranscription)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(
                    memoryPressure: .critical,
                    hasForegroundAction: true)
            ).disposition,
            .admitWithReducedConcurrency)
    }

    func testSeverePressurePausesOnlyAtCheckpoint() {
        let request = request(
            workloadClass: .postCapture,
            kind: .qualityTranscription,
            phase: .checkpoint)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(memoryPressure: .critical)
            ).disposition,
            .pauseAfterCheckpoint)
    }

    func testMaintenanceDefersOnBatteryOrLowPowerMode() {
        let request = request(
            workloadClass: .maintenance,
            kind: .librarySync)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(powerSource: .battery)
            ).disposition,
            .defer(until: .externalPower))
        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(isLowPowerModeEnabled: true)
            ).disposition,
            .defer(until: .lowPowerModeDisabled))
    }

    func testMaintenancePausesAtCheckpointOnBattery() {
        let request = request(
            workloadClass: .maintenance,
            kind: .librarySync,
            phase: .checkpoint)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(powerSource: .battery)
            ).disposition,
            .pauseAfterCheckpoint)
    }

    func testPressureEvictsOnlyIdleUnrelatedModelsInStableOrder() {
        let request = request(
            workloadClass: .userInitiated,
            kind: .languageInference)
        let snapshot = snapshot(
            memoryPressure: .warning,
            residentModels: [
                resident(.semanticEmbedding),
                resident(.languageIntelligence),
                resident(.qualitySpeech, isIdle: false),
                resident(.liveSpeech),
                resident(.semanticEmbedding)
            ])

        XCTAssertEqual(
            policy.evaluate(request: request, snapshot: snapshot).evictIdleModels,
            [.liveSpeech, .semanticEmbedding])
    }

    func testNominalHostDoesNotEvictIdleModels() {
        let request = request(
            workloadClass: .userInitiated,
            kind: .languageInference)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(
                    residentModels: [resident(.qualitySpeech)])
            ).evictIdleModels,
            [])
    }

    func testModelReleaseIsAdmittedAndCanEvictItsOwnIdleFamily() {
        let request = request(
            workloadClass: .maintenance,
            kind: .languageInference,
            operation: .release)

        XCTAssertEqual(
            policy.evaluate(
                request: request,
                snapshot: snapshot(
                    diskState: .critical,
                    memoryPressure: .critical,
                    residentModels: [resident(.languageIntelligence)])
            ),
            ResourceGovernorDecision(
                disposition: .admitNow,
                evictIdleModels: [.languageIntelligence]))
    }
}

private func request(
    workloadClass: ResourceWorkloadClass,
    kind: ResourceWorkloadKind = .uiProjection,
    operation: ResourceWorkloadOperation = .execute,
    phase: ResourceGovernorEvaluationPhase = .admission
) -> ResourceGovernorRequest {
    ResourceGovernorRequest(
        descriptor: ResourceWorkloadDescriptor(
            workloadClass: workloadClass,
            kind: kind,
            operation: operation),
        phase: phase)
}

private func snapshot(
    captureState: ResourceCaptureState = .inactive,
    sourceHealth: ResourceCaptureSourceHealth = .healthy,
    memoryTier: ResourceMemoryTier = .standard,
    diskState: ResourceDiskState = .sufficient,
    memoryPressure: ResourceMemoryPressure = .nominal,
    thermalState: ResourceThermalState = .nominal,
    residentModels: [ResourceResidentModel] = [],
    hasForegroundAction: Bool = false,
    durableBacklog: ResourceDurableBacklog = .empty,
    powerSource: ResourcePowerSource = .external,
    isLowPowerModeEnabled: Bool = false
) -> ResourceGovernorSnapshot {
    ResourceGovernorSnapshot(
        capture: ResourceCaptureSnapshot(
            state: captureState,
            sourceHealth: sourceHealth),
        memoryTier: memoryTier,
        diskState: diskState,
        memoryPressure: memoryPressure,
        thermalState: thermalState,
        residentModels: residentModels,
        hasForegroundAction: hasForegroundAction,
        durableBacklog: durableBacklog,
        powerSource: powerSource,
        isLowPowerModeEnabled: isLowPowerModeEnabled)
}

private func resident(
    _ family: ResourceModelFamily,
    footprint: UInt64? = 1,
    isIdle: Bool = true
) -> ResourceResidentModel {
    ResourceResidentModel(
        family: family,
        measuredFootprintBytes: footprint,
        isIdle: isIdle)
}
