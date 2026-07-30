import Dispatch
import Foundation
import PortavozCore
import XCTest
@testable import portavoz_app

final class AppResourceGovernorReleaseTests: XCTestCase {
    func testWarningPressureRequestsOnlyIdleFamiliesInStableOrder() {
        let families = AppResourceGovernorReleasePlan.families(
            pressure: AppResourcePressureSnapshot(
                memory: .warning,
                thermal: .nominal),
            captureState: .active,
            residentModels: [
                resident(.semanticEmbedding),
                resident(.languageIntelligence),
                resident(.qualitySpeech, isIdle: false),
                resident(.liveSpeech),
                resident(.semanticEmbedding),
            ])

        XCTAssertEqual(
            families,
            [.liveSpeech, .languageIntelligence, .semanticEmbedding])
    }

    func testSeriousThermalPressureRequestsIdleRelease() {
        XCTAssertEqual(
            AppResourceGovernorReleasePlan.families(
                pressure: AppResourcePressureSnapshot(
                    memory: .nominal,
                    thermal: .serious),
                captureState: .inactive,
                residentModels: [resident(.speakerDiarization)]),
            [.speakerDiarization])
    }

    func testNominalAndFairHostRequestsNoRelease() {
        XCTAssertEqual(
            AppResourceGovernorReleasePlan.families(
                pressure: AppResourcePressureSnapshot(
                    memory: .nominal,
                    thermal: .fair),
                captureState: .inactive,
                residentModels: [resident(.semanticEmbedding)]),
            [])
    }

    func testProtectedCaptureReleasesIdleWhisperAndMLXWithoutHostPressure() {
        XCTAssertEqual(
            AppResourceGovernorReleasePlan.families(
                pressure: .nominal,
                captureState: .active,
                residentModels: [
                    resident(.qualitySpeech),
                    resident(.languageIntelligence)
                ]),
            [.qualitySpeech, .languageIntelligence])
    }

    func testMLXAdmissionEvictsIdleWhisperDuringProtectedCapture() {
        let decision = AppResourceGovernorModelLoadPlan.decision(
            target: .languageIntelligence,
            captureState: .active,
            residencyRecords: [record(.qualitySpeech)])

        XCTAssertEqual(
            decision,
            ResourceGovernorDecision(
                disposition: .admitWithReducedConcurrency,
                evictIdleModels: [.qualitySpeech]))
        XCTAssertTrue(
            AppResourceGovernorModelLoadPlan.blocks(
                decision: decision,
                target: .languageIntelligence))
    }

    func testWhisperAdmissionDefersWhenMLXIsBusyDuringProtectedCapture() {
        let decision = AppResourceGovernorModelLoadPlan.decision(
            target: .qualitySpeech,
            captureState: .stopping,
            residencyRecords: [
                record(.languageIntelligence, activeUseCount: 1)
            ])

        XCTAssertEqual(
            decision.disposition,
            .defer(until: .captureStops))
        XCTAssertTrue(
            AppResourceGovernorModelLoadPlan.blocks(
                decision: decision,
                target: .qualitySpeech))
    }

    func testHeavyPairAdmissionClearsAfterPeerRelease() {
        let decision = AppResourceGovernorModelLoadPlan.decision(
            target: .languageIntelligence,
            captureState: .active,
            residencyRecords: [])

        XCTAssertFalse(
            AppResourceGovernorModelLoadPlan.blocks(
                decision: decision,
                target: .languageIntelligence))
    }

    func testLoadingWhisperDefersMLXDuringProtectedCapture() {
        let decision = AppResourceGovernorModelLoadPlan.decision(
            target: .languageIntelligence,
            captureState: .active,
            residencyRecords: [
                record(.qualitySpeech, status: .loading)
            ])

        XCTAssertEqual(
            decision.disposition,
            .defer(until: .captureStops))
        XCTAssertTrue(
            AppResourceGovernorModelLoadPlan.blocks(
                decision: decision,
                target: .languageIntelligence))
    }

    func testCaptureStateMirrorIsContentFreeAndSynchronous() {
        let state = AppResourceCaptureState()

        XCTAssertEqual(state.current, .inactive)
        state.update(.starting)
        XCTAssertEqual(state.current, .starting)
        state.update(.active)
        XCTAssertEqual(state.current, .active)
        state.update(.stopping)
        XCTAssertEqual(state.current, .stopping)
        state.update(.inactive)
        XCTAssertEqual(state.current, .inactive)
    }

    func testPlatformPressureMappingIsClosedAndDeterministic() {
        XCTAssertFalse(
            AppResourcePressureSnapshot(
                memory: .nominal,
                thermal: .fair
            ).requestsIdleModelRelease)
        XCTAssertTrue(
            AppResourcePressureSnapshot(
                memory: .warning,
                thermal: .nominal
            ).requestsIdleModelRelease)
        XCTAssertTrue(
            AppResourcePressureSnapshot(
                memory: .nominal,
                thermal: .serious
            ).requestsIdleModelRelease)
        XCTAssertEqual(
            AppResourcePressureMonitor.memoryPressure(.normal),
            .nominal)
        XCTAssertEqual(
            AppResourcePressureMonitor.memoryPressure(.warning),
            .warning)
        XCTAssertEqual(
            AppResourcePressureMonitor.memoryPressure([.warning, .critical]),
            .critical)
        XCTAssertEqual(
            AppResourcePressureMonitor.thermalState(.nominal),
            .nominal)
        XCTAssertEqual(
            AppResourcePressureMonitor.thermalState(.fair),
            .fair)
        XCTAssertEqual(
            AppResourcePressureMonitor.thermalState(.serious),
            .serious)
        XCTAssertEqual(
            AppResourcePressureMonitor.thermalState(.critical),
            .critical)
    }

    func testLastUseNotifiesCompositionOutsideLedgerLockExactlyOnce() throws {
        let ledger = AppModelResidencyLedger()
        let recorder = IdleObserverRecorder()
        ledger.installIdleObserver { family in
            recorder.append(
                family,
                activeUseCount: ledger.record(for: family).activeUseCount)
        }
        guard let load = ledger.beginLoad(.semanticEmbedding) else {
            return XCTFail("Expected semantic load")
        }
        XCTAssertTrue(ledger.finishLoad(load, measuredFootprintBytes: nil))
        let first = try XCTUnwrap(ledger.beginUse(.semanticEmbedding))
        let second = try XCTUnwrap(ledger.beginUse(.semanticEmbedding))

        XCTAssertTrue(ledger.finishUse(first))
        XCTAssertEqual(recorder.events, [])
        XCTAssertTrue(ledger.finishUse(second))
        XCTAssertFalse(ledger.finishUse(second))

        XCTAssertEqual(
            recorder.events,
            [IdleObserverEvent(
                family: .semanticEmbedding,
                activeUseCount: 0)])
    }

    private func resident(
        _ family: ResourceModelFamily,
        isIdle: Bool = true
    ) -> ResourceResidentModel {
        ResourceResidentModel(
            family: family,
            measuredFootprintBytes: nil,
            isIdle: isIdle)
    }

    private func record(
        _ family: ResourceModelFamily,
        status: ResourceModelResidencyStatus = .resident,
        activeUseCount: Int = 0
    ) -> ResourceModelResidencyRecord {
        ResourceModelResidencyRecord(
            family: family,
            status: status,
            activeUseCount: activeUseCount,
            measuredFootprintBytes: nil)
    }
}

private struct IdleObserverEvent: Equatable {
    let family: ResourceModelFamily
    let activeUseCount: Int
}

private final class IdleObserverRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [IdleObserverEvent] = []

    var events: [IdleObserverEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(
        _ family: ResourceModelFamily,
        activeUseCount: Int
    ) {
        lock.lock()
        storage.append(IdleObserverEvent(
            family: family,
            activeUseCount: activeUseCount))
        lock.unlock()
    }
}
