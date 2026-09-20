import ApplicationKit
import Darwin
import Foundation
import PortavozCore
import StorageKit
import XCTest
@testable import PlatformKit
@testable import portavoz_app

@MainActor
final class HostSupportDiagnosticsTests: XCTestCase {
    func testActualAppExportContainsHostResourcesWithoutContent() async throws {
        try await assertActualAppExportContainsHostResourcesWithoutContent()
    }

    private func assertActualAppExportContainsHostResourcesWithoutContent() async throws {
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:])
        let meeting = Meeting(title: "SECRET reunión — Don't export", startedAt: Date())
        try await services.store.save(meeting)
        let cpuBefore = try processCPUSeconds()
        let data = try await services.exportSupportDiagnostics()
        let cpuAfter = try processCPUSeconds()
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let environment = try XCTUnwrap(report["environment"] as? [String: Any])
        let host = try XCTUnwrap(environment["host"] as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(host["physicalMemoryBytes"] as? UInt64), 0)
        assertCPUSeconds(try XCTUnwrap(host["processCPUSeconds"] as? Double), between: cpuBefore, and: cpuAfter)
        XCTAssertNotNil(host["thermalState"])
        let residency = try XCTUnwrap(host["modelResidency"] as? [[String: Any]])
        XCTAssertEqual(residency.count, ResourceModelFamily.allCases.count)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(NSHomeDirectory()))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(meeting.title))
        XCTAssertEqual(report["formatVersion"] as? Int, 3)
        XCTAssertEqual(Set(host.keys), [
            "physicalMemoryBytes", "processFootprintBytes", "processCPUSeconds",
            "thermalState", "lowPowerModeEnabled", "modelResidency"
        ]) // Only sampled host fields belong in the report.
    }

    func testActualExportDoesNotPromoteGovernorDefaultsToObservedPressure() async throws {
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:])
        // The governor publishes its nominal policy default before the first
        // dispatch event. That default is not a sampled host measurement.
        services.resourcePressureMonitor = AppResourcePressureMonitor { _ in }
        defer { services.resourcePressureMonitor = nil }
        XCTAssertEqual(services.resourcePressureMonitor?.current.memory, .nominal)
        let data = try await services.exportSupportDiagnostics()
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let environment = try XCTUnwrap(report["environment"] as? [String: Any])
        let host = try XCTUnwrap(environment["host"] as? [String: Any])
        XCTAssertNil(host["memoryPressure"], "Do not export an unsampled policy default as a host fact")
        XCTAssertNotNil(host["thermalState"], "The native thermal snapshot remains independently available")
    }

    func testUnknownThermalObservationRemainsAbsentAtActualExportBoundary() async throws {
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:])
        let known: [(ProcessInfo.ThermalState, ResourceThermalState)] = [
            (.nominal, .nominal), (.fair, .fair), (.serious, .serious), (.critical, .critical)
        ]
        for (native, reported) in known {
            XCTAssertEqual(services.supportHostDiagnostics(thermalState: native).thermalState, reported)
        }
        let unknown = try XCTUnwrap(ProcessInfo.ThermalState(rawValue: 99))
        let snapshot = services.supportHostDiagnostics(thermalState: unknown)
        let data = try await ExportSupportDiagnostics(store: services.store).execute(
            .init(environment: .init(appVersion: "test", buildVersion: "1", operatingSystem: "test",
                                     models: [], host: snapshot)))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let environment = try XCTUnwrap(report["environment"] as? [String: Any])
        let host = try XCTUnwrap(environment["host"] as? [String: Any])
        XCTAssertNil(host["thermalState"], "A future native state must not become the governor's fair fallback")
        XCTAssertGreaterThan(try XCTUnwrap(host["physicalMemoryBytes"] as? UInt64), 0)
    }

    func testUnavailableProcessReadKeepsOwnersAndDoesNotInventZeros() async throws {
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:])
        let ticket = try XCTUnwrap(services.modelResidencyLedger.beginLoad(.liveSpeech))
        let lease = try XCTUnwrap(services.modelResidencyLedger.finishLoadAndBeginUse(
            ticket, measuredFootprintBytes: nil))
        var reads = 0
        let host = services.supportHostDiagnostics {
            reads += 1
            throw OwnProcessResourceUsage.ReadError.unavailable
        }
        XCTAssertEqual(reads, 1)
        XCTAssertNil(host.processFootprintBytes)
        XCTAssertNil(host.processCPUSeconds)
        let live = try XCTUnwrap(host.modelResidency.first { $0.family == .liveSpeech })
        XCTAssertEqual(live.status, .resident)
        XCTAssertEqual(live.activeUseCount, 1)
        XCTAssertNil(live.measuredFootprintBytes)
        XCTAssertTrue(services.modelResidencyLedger.finishUse(lease), "Export must not consume a model lease")
    }

    func testDecodedMalformedEvidenceIsSanitizedAtExportCallSite() async throws {
        let json = #"{"physicalMemoryBytes":42,"processCPUSeconds":-1,"thermalState":"critical","lowPowerModeEnabled":true,"modelResidency":[{"family":"liveSpeech","status":"resident","activeUseCount":1},{"family":"liveSpeech","status":"unloaded","activeUseCount":0},{"family":"qualitySpeech","status":"resident","activeUseCount":-1}]}"#
        let host = try JSONDecoder().decode(SupportHostDiagnostics.self, from: Data(json.utf8))
        let data = try await ExportSupportDiagnostics(store: MeetingStore.inMemory()).execute(
            .init(environment: .init(appVersion: "test", buildVersion: "1", operatingSystem: "test",
                                     models: [], host: host)))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(SupportDiagnosticsReport.self, from: data)
        XCTAssertNil(report.environment.host?.processCPUSeconds)
        XCTAssertEqual(report.environment.host?.modelResidency, [])
        XCTAssertEqual(report.environment.host?.thermalState, .critical)
        XCTAssertThrowsError(try JSONDecoder().decode(SupportHostDiagnostics.self, from:
            Data(json.replacingOccurrences(of: "critical", with: "SECRET arbitrary state").utf8)))
    }

    func testOldEnvironmentDecodesWithoutFabricatedHostMeasurements() async throws {
        let data = Data(#"{"appVersion":"1","buildVersion":"1","operatingSystem":"test","models":[]}"#.utf8)
        let environment = try JSONDecoder().decode(SupportDiagnosticsEnvironment.self, from: data)
        XCTAssertNil(environment.host)
        let exported = try await ExportSupportDiagnostics(store: MeetingStore.inMemory()).execute(
            .init(environment: environment))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        legacy["formatVersion"] = 2
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(SupportDiagnosticsReport.self, from:
            JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(report.formatVersion, 2)
        XCTAssertNil(report.environment.host)
    }

    func testProcessCounterUnitsAndUnsupportedValues() async throws {
        XCTAssertEqual(OwnProcessResourceUsage.seconds(ticks: 24_000_000, numerator: 125, denominator: 3), 1)
        XCTAssertEqual(OwnProcessResourceUsage.seconds(ticks: 0, numerator: 1, denominator: 1), 0)
        XCTAssertNil(OwnProcessResourceUsage.seconds(ticks: 1, numerator: 0, denominator: 1))
        XCTAssertNil(OwnProcessResourceUsage.seconds(ticks: 1, numerator: 1, denominator: 0))
        XCTAssertTrue(try XCTUnwrap(OwnProcessResourceUsage.seconds(
            ticks: .max, numerator: .max, denominator: 1)).isFinite)
        let actual = try OwnProcessResourceUsage.current()
        XCTAssertGreaterThan(actual.physicalFootprintBytes, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(actual.cpuSeconds), 0)
        XCTAssertNil(actual.energyNanojoules, "V0 does not measure extended counters")
        XCTAssertNil(actual.diskReadBytes)
        XCTAssertNil(actual.diskWrittenBytes)
    }

    func testNativeCPUUnitsMatchIndependentProcessAccounting() async throws {
        try assertNativeCPUUnitsMatchIndependentProcessAccounting()
    }

    private func assertNativeCPUUnitsMatchIndependentProcessAccounting() throws {
        // Both native flavors must expose the same units. Checking only the
        // pure conversion would pass even if the adapter fed it nanoseconds.
        for extendedCounters in [false, true] {
            let before = try processCPUSeconds()
            let actual = try OwnProcessResourceUsage.current(extendedCounters: extendedCounters)
            let after = try processCPUSeconds()
            assertCPUSeconds(try XCTUnwrap(actual.cpuSeconds), between: before, and: after)
        }
    }

    func testNativeCPUAccountingIncludesTerminatedThreads() async throws {
        let before = try processCPUSeconds()
        try runTerminatingWorkers()
        let after = try processCPUSeconds()
        XCTAssertGreaterThan(after, before, "Retired worker CPU must remain part of process accounting")
        try assertNativeCPUUnitsMatchIndependentProcessAccounting()
        try await assertActualAppExportContainsHostResourcesWithoutContent()
    }

    private func runTerminatingWorkers() throws {
        var threads: [pthread_t] = []
        defer {
            for thread in threads { XCTAssertEqual(pthread_join(thread, nil), 0) }
        }
        for _ in 0..<8 {
            var thread: pthread_t?
            let result = pthread_create(&thread, nil, { _ in
                // Finite native work, not a sleep or an elapsed-time threshold.
                for _ in 0..<2_048 { _ = Darwin.getpid() }
                return nil
            }, nil)
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
            threads.append(try XCTUnwrap(thread))
        }
    }

    private func processCPUSeconds() throws -> Double {
        // Sequoia getrusage rounds each live thread separately and reads retired
        // threads in another snapshot. No fixed microsecond allowance fixes that.
        // TASK_ABSOLUTETIME_INFO keeps native precision and includes retired work.
        var times = task_absolutetime_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_absolutetime_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &times) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_ABSOLUTETIME_INFO), $0, &count)
            }
        }
        var timebase = mach_timebase_info_data_t()
        guard result == KERN_SUCCESS, mach_timebase_info(&timebase) == KERN_SUCCESS,
              timebase.numer > 0, timebase.denom > 0 else { throw POSIXError(.EIO) }
        let total = times.total_user.addingReportingOverflow(times.total_system)
        guard !total.overflow else { throw POSIXError(.EOVERFLOW) }
        // Independent API and conversion: do not call the production helper.
        return Double(total.partialValue) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    private func assertCPUSeconds(
        _ actual: Double, between before: Double, and after: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertGreaterThan(before, 0, "A zero-work oracle cannot detect a unit mismatch", file: file, line: line)
        XCTAssertGreaterThanOrEqual(after, before, file: file, line: line)
        XCTAssertGreaterThanOrEqual(actual, before, file: file, line: line)
        XCTAssertLessThanOrEqual(actual, after, file: file, line: line)
    }
}
