import XCTest
@testable import PortavozCore

final class ResourceModelResidencyTests: XCTestCase {
    func testTaxonomiesRemainClosedAndStable() {
        XCTAssertEqual(
            ResourceModelResidencyStatus.allCases.map(\.rawValue),
            ["unloaded", "loading", "resident", "releasing"])
        XCTAssertEqual(
            ResourceModelFamily.allCases.map(\.rawValue),
            [
                "liveSpeech",
                "qualitySpeech",
                "speakerDiarization",
                "languageIntelligence",
                "semanticEmbedding",
            ])
    }

    func testEveryFamilyStartsUnloaded() {
        let ledger = ResourceModelResidencyLedger()

        XCTAssertEqual(
            ledger.records,
            ResourceModelFamily.allCases.map {
                ResourceModelResidencyRecord(
                    family: $0,
                    status: .unloaded,
                    activeUseCount: 0,
                    measuredFootprintBytes: nil)
            })
        XCTAssertTrue(ledger.residentModels.isEmpty)
    }

    func testOnlyOneLoadCanOwnAFamily() throws {
        var ledger = ResourceModelResidencyLedger()

        let ticket = try XCTUnwrap(ledger.beginLoad(.liveSpeech))

        XCTAssertNil(ledger.beginLoad(.liveSpeech))
        XCTAssertEqual(ledger.record(for: .liveSpeech).status, .loading)
        XCTAssertTrue(ledger.finishLoad(ticket, measuredFootprintBytes: 600))
        XCTAssertEqual(ledger.record(for: .liveSpeech).status, .resident)
    }

    func testDifferentFamiliesLoadIndependently() throws {
        var ledger = ResourceModelResidencyLedger()

        let live = try XCTUnwrap(ledger.beginLoad(.liveSpeech))
        let quality = try XCTUnwrap(ledger.beginLoad(.qualitySpeech))

        XCTAssertTrue(ledger.finishLoad(live, measuredFootprintBytes: nil))
        XCTAssertTrue(ledger.finishLoad(quality, measuredFootprintBytes: nil))
        XCTAssertEqual(
            ledger.residentModels.map(\.family),
            [.liveSpeech, .qualitySpeech])
    }

    func testFailedLoadReturnsOnlyItsCurrentFamilyToUnloaded() throws {
        var ledger = ResourceModelResidencyLedger()
        let live = try XCTUnwrap(ledger.beginLoad(.liveSpeech))
        let diarization = try XCTUnwrap(ledger.beginLoad(.speakerDiarization))

        XCTAssertTrue(ledger.failLoad(live))
        XCTAssertEqual(ledger.record(for: .liveSpeech).status, .unloaded)
        XCTAssertEqual(
            ledger.record(for: .speakerDiarization).status,
            .loading)
        XCTAssertTrue(ledger.finishLoad(diarization, measuredFootprintBytes: nil))
    }

    func testStaleLoadCompletionCannotPublishRuntime() throws {
        var ledger = ResourceModelResidencyLedger()
        let old = try XCTUnwrap(ledger.beginLoad(.qualitySpeech))
        XCTAssertTrue(ledger.failLoad(old))
        let current = try XCTUnwrap(ledger.beginLoad(.qualitySpeech))

        XCTAssertFalse(ledger.finishLoad(old, measuredFootprintBytes: 1))
        XCTAssertEqual(ledger.record(for: .qualitySpeech).status, .loading)
        XCTAssertTrue(ledger.finishLoad(current, measuredFootprintBytes: 2))
        XCTAssertEqual(
            ledger.record(for: .qualitySpeech).measuredFootprintBytes,
            2)
    }

    func testUseLeaseMakesResidentRuntimeBusy() throws {
        var ledger = try residentLedger(.speakerDiarization, footprint: 400)

        let first = try XCTUnwrap(ledger.beginUse(.speakerDiarization))
        let second = try XCTUnwrap(ledger.beginUse(.speakerDiarization))

        XCTAssertEqual(
            ledger.record(for: .speakerDiarization).activeUseCount,
            2)
        XCTAssertEqual(
            ledger.residentModels,
            [ResourceResidentModel(
                family: .speakerDiarization,
                measuredFootprintBytes: 400,
                isIdle: false)])
        XCTAssertNil(ledger.beginRelease(.speakerDiarization))
        XCTAssertTrue(ledger.finishUse(first))
        XCTAssertTrue(ledger.finishUse(second))
        XCTAssertTrue(ledger.residentModels[0].isIdle)
    }

    func testDuplicateUseCompletionIsInert() throws {
        var ledger = try residentLedger(.semanticEmbedding)
        let lease = try XCTUnwrap(ledger.beginUse(.semanticEmbedding))

        XCTAssertTrue(ledger.finishUse(lease))
        XCTAssertFalse(ledger.finishUse(lease))
        XCTAssertEqual(
            ledger.record(for: .semanticEmbedding).activeUseCount,
            0)
    }

    func testReleaseRequiresIdleResidentRuntime() throws {
        var ledger = ResourceModelResidencyLedger()

        XCTAssertNil(ledger.beginRelease(.languageIntelligence))
        let load = try XCTUnwrap(ledger.beginLoad(.languageIntelligence))
        XCTAssertNil(ledger.beginRelease(.languageIntelligence))
        XCTAssertTrue(ledger.finishLoad(load, measuredFootprintBytes: nil))
        let lease = try XCTUnwrap(ledger.beginUse(.languageIntelligence))
        XCTAssertNil(ledger.beginRelease(.languageIntelligence))
        XCTAssertTrue(ledger.finishUse(lease))
        XCTAssertNotNil(ledger.beginRelease(.languageIntelligence))
    }

    func testReleasingRuntimeRemainsInGovernorProjectionUntilFinished() throws {
        var ledger = try residentLedger(.qualitySpeech, footprint: 1_024)
        let release = try XCTUnwrap(ledger.beginRelease(.qualitySpeech))

        XCTAssertEqual(ledger.record(for: .qualitySpeech).status, .releasing)
        XCTAssertEqual(
            ledger.residentModels,
            [ResourceResidentModel(
                family: .qualitySpeech,
                measuredFootprintBytes: 1_024,
                isIdle: true)])
        XCTAssertNil(ledger.beginUse(.qualitySpeech))
        XCTAssertTrue(ledger.finishRelease(release))
        XCTAssertEqual(ledger.record(for: .qualitySpeech).status, .unloaded)
        XCTAssertTrue(ledger.residentModels.isEmpty)
    }

    func testCancelledReleaseRestoresResidentRuntime() throws {
        var ledger = try residentLedger(.liveSpeech)
        let release = try XCTUnwrap(ledger.beginRelease(.liveSpeech))

        XCTAssertTrue(ledger.cancelRelease(release))
        XCTAssertEqual(ledger.record(for: .liveSpeech).status, .resident)
        XCTAssertNotNil(ledger.beginUse(.liveSpeech))
        XCTAssertFalse(ledger.finishRelease(release))
    }

    func testStaleReleaseCannotRemoveNewerState() throws {
        var ledger = try residentLedger(.qualitySpeech)
        let stale = try XCTUnwrap(ledger.beginRelease(.qualitySpeech))
        XCTAssertTrue(ledger.cancelRelease(stale))
        let current = try XCTUnwrap(ledger.beginRelease(.qualitySpeech))

        XCTAssertFalse(ledger.finishRelease(stale))
        XCTAssertEqual(ledger.record(for: .qualitySpeech).status, .releasing)
        XCTAssertTrue(ledger.finishRelease(current))
    }

    func testMeasuredFootprintsAreCarriedNotInterpreted() throws {
        var ledger = try residentLedger(
            .languageIntelligence,
            footprint: UInt64.max)

        XCTAssertEqual(
            ledger.record(for: .languageIntelligence).measuredFootprintBytes,
            UInt64.max)
        XCTAssertNotNil(ledger.beginUse(.languageIntelligence))
    }
}

private func residentLedger(
    _ family: ResourceModelFamily,
    footprint: UInt64? = nil
) throws -> ResourceModelResidencyLedger {
    var ledger = ResourceModelResidencyLedger()
    let ticket = try XCTUnwrap(ledger.beginLoad(family))
    XCTAssertTrue(ledger.finishLoad(
        ticket,
        measuredFootprintBytes: footprint))
    return ledger
}
