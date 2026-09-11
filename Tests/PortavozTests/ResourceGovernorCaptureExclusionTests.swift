import PortavozCore
import XCTest

final class ResourceGovernorCaptureExclusionTests: XCTestCase {
    private let policy = ResourceGovernorPolicy()

    func testUnknownHostEvictsIdleWhisperBeforeMLXLoadDuringCapture() {
        XCTAssertEqual(
            policy.evaluate(
                request: captureRequest(
                    workloadClass: .userInitiated,
                    kind: .languageInference,
                    operation: .load),
                snapshot: captureSnapshot(
                    captureState: .active,
                    memoryTier: .unknown,
                    residentModels: [captureResident(.qualitySpeech)])
            ),
            ResourceGovernorDecision(
                disposition: .admitWithReducedConcurrency,
                evictIdleModels: [.qualitySpeech]))
    }

    func testUnknownHostDefersMLXWhenWhisperIsBusyDuringCapture() {
        XCTAssertEqual(
            policy.evaluate(
                request: captureRequest(
                    workloadClass: .userInitiated,
                    kind: .languageInference,
                    operation: .load),
                snapshot: captureSnapshot(
                    captureState: .active,
                    memoryTier: .unknown,
                    residentModels: [
                        captureResident(.qualitySpeech, isIdle: false)
                    ])
            ),
            ResourceGovernorDecision(
                disposition: .defer(until: .captureStops)))
    }

    func testStandardHostAllowsHeavyPairDuringCapture() {
        XCTAssertEqual(
            policy.evaluate(
                request: captureRequest(
                    workloadClass: .userInitiated,
                    kind: .languageInference,
                    operation: .load),
                snapshot: captureSnapshot(
                    captureState: .active,
                    memoryTier: .standard,
                    residentModels: [
                        captureResident(.qualitySpeech, isIdle: false)
                    ])
            ),
            ResourceGovernorDecision(
                disposition: .admitWithReducedConcurrency))
    }

    func testProtectedCaptureReleaseEvictsIdleHeavyPairOnUnknownHost() {
        XCTAssertEqual(
            policy.evaluate(
                request: captureRequest(
                    workloadClass: .maintenance,
                    kind: .uiProjection,
                    operation: .release),
                snapshot: captureSnapshot(
                    captureState: .starting,
                    memoryTier: .unknown,
                    residentModels: [
                        captureResident(.qualitySpeech),
                        captureResident(.languageIntelligence)
                    ])
            ).evictIdleModels,
            [.qualitySpeech, .languageIntelligence])
    }
}

private func captureRequest(
    workloadClass: ResourceWorkloadClass,
    kind: ResourceWorkloadKind,
    operation: ResourceWorkloadOperation
) -> ResourceGovernorRequest {
    ResourceGovernorRequest(
        descriptor: ResourceWorkloadDescriptor(
            workloadClass: workloadClass,
            kind: kind,
            operation: operation),
        phase: .admission)
}

private func captureSnapshot(
    captureState: ResourceCaptureState,
    memoryTier: ResourceMemoryTier,
    residentModels: [ResourceResidentModel]
) -> ResourceGovernorSnapshot {
    ResourceGovernorSnapshot(
        capture: ResourceCaptureSnapshot(
            state: captureState,
            sourceHealth: .healthy),
        memoryTier: memoryTier,
        diskState: .sufficient,
        memoryPressure: .nominal,
        thermalState: .nominal,
        residentModels: residentModels,
        hasForegroundAction: false,
        durableBacklog: .empty,
        powerSource: .external,
        isLowPowerModeEnabled: false)
}

private func captureResident(
    _ family: ResourceModelFamily,
    isIdle: Bool = true
) -> ResourceResidentModel {
    ResourceResidentModel(
        family: family,
        measuredFootprintBytes: nil,
        isIdle: isIdle)
}
