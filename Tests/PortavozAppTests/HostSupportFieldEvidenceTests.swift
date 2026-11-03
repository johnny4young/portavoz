import ApplicationKit
import Darwin
import Foundation
import PortavozCore
import XCTest
@testable import portavoz_app

@MainActor
final class HostSupportFieldEvidenceTests: XCTestCase {
    func testActualAppExportSurvivesCollectionAndReliabilityValidation() async throws {
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:])
        try await services.store.save(Meeting(title: "PRIVATE reunión — Don't include", startedAt: Date()))
        let data = try await services.exportSupportDiagnostics()
        try await validateWithActualConsumers(data)
    }

    func testEveryTypedResidencyStateSurvivesExportAndCollection() async throws {
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:])
        try await services.store.save(Meeting(title: "Synthetic", startedAt: Date()))
        for status in ResourceModelResidencyStatus.allCases {
            let host = SupportHostDiagnostics(
                physicalMemoryBytes: 1, processFootprintBytes: nil, processCPUSeconds: nil,
                thermalState: nil, lowPowerModeEnabled: false,
                modelResidency: ResourceModelFamily.allCases.map {
                    .init(family: $0, status: status, activeUseCount: 0, measuredFootprintBytes: nil)
                })
            let data = try await ExportSupportDiagnostics(store: services.store).execute(
                .init(environment: .init(appVersion: "1.0.0", buildVersion: "1",
                                        operatingSystem: "macOS 26.0", models: [], host: host)))
            try await validateWithActualConsumers(data)
        }
    }

    private func validateWithActualConsumers(_ data: Data) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("support.json")
        try data.write(to: report, options: .atomic)

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [repository.appendingPathComponent(
            "Tests/Tooling/validate_exported_support.py").path, report.path]
        let output = root.appendingPathComponent("collector.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        let exited = expectation(description: "Support consumer exits")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        defer {
            if process.isRunning {
                // Only this test's child. A timeout must not leave a reader
                // running while its synthetic report directory is removed.
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        await fulfillment(of: [exited], timeout: 10)
        guard !process.isRunning else { return }
        let diagnostic = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(process.terminationReason, .exit, diagnostic)
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        XCTAssertTrue(diagnostic.contains("support-roundtrip=validated"), diagnostic)
    }
}
