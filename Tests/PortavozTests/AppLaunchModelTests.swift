import Foundation
import XCTest

@testable import portavoz_app

@MainActor
final class AppLaunchModelTests: XCTestCase {
    func testFailureProducesContentFreeDiagnosticWithoutConstructingNormalUI() throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let databaseURL = workspace.appendingPathComponent(
            "private-person-name-secret.sqlite")
        try Data("private transcript phrase".utf8).write(to: databaseURL)
        let rawMessage = "raw failure with /Users/private/person and transcript"
        let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
        let model = AppLaunchModel(
            arguments: ["Portavoz", "-use-temp-store"],
            environment: ["PORTAVOZ_UI_TEST_DATABASE_PATH": databaseURL.path],
            now: { timestamp },
            servicesFactory: { throw LaunchTestError(message: rawMessage) })

        guard case let .databaseUnavailable(failure) = model.phase else {
            return XCTFail("Expected the recovery phase")
        }
        XCTAssertTrue(failure.databaseFilePresent)
        XCTAssertEqual(failure.databaseFileBytes, 25)
        XCTAssertNil(model.services)

        let data = try model.diagnosticData(for: failure, generatedAt: timestamp)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(databaseURL.path))
        XCTAssertFalse(json.contains(databaseURL.lastPathComponent))
        XCTAssertFalse(json.contains(rawMessage))
        XCTAssertFalse(json.contains("private transcript phrase"))
        XCTAssertTrue(json.contains(#""authority" : "system""#))
        XCTAssertTrue(json.contains(#""filePresent" : true"#))
    }

    func testRetryCanReplaceFailureWithOneCompleteServiceGraph() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let databaseURL = workspace.appendingPathComponent("retry.sqlite")
        let arguments = ["Portavoz", "-use-temp-store"]
        let environment = ["PORTAVOZ_UI_TEST_DATABASE_PATH": databaseURL.path]
        var attempts = 0
        let model = AppLaunchModel(
            arguments: arguments,
            environment: environment,
            servicesFactory: {
                attempts += 1
                if attempts == 1 {
                    throw LaunchTestError(message: "first attempt")
                }
                return try AppServices(
                    arguments: arguments,
                    environment: environment)
            })
        XCTAssertNil(model.services)

        await model.retry()

        XCTAssertEqual(attempts, 2)
        XCTAssertNotNil(model.services)
        guard case .ready = model.phase else {
            return XCTFail("Expected retry to publish the complete service graph")
        }
    }

    func testDiagnosticExportIsPrivateAndTracksOnlyBoundedState() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let databaseURL = workspace.appendingPathComponent("failed.sqlite")
        try Data("not user content".utf8).write(to: databaseURL)
        let destination = workspace.appendingPathComponent("diagnostics.json")
        try Data("stale diagnostics".utf8).write(to: destination)
        let model = AppLaunchModel(
            arguments: ["Portavoz", "-use-temp-store"],
            environment: ["PORTAVOZ_UI_TEST_DATABASE_PATH": databaseURL.path],
            servicesFactory: { throw LaunchTestError(message: "private raw error") })

        await model.exportDiagnostics(to: destination)

        XCTAssertEqual(model.diagnosticsState, .succeeded)
        XCTAssertEqual(try permissions(of: destination), 0o600)
        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertFalse(exported.contains(databaseURL.path))
        XCTAssertFalse(exported.contains("private raw error"))
        XCTAssertFalse(exported.contains("stale diagnostics"))
        let leavesHiddenStage = try FileManager.default.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: nil).contains {
            $0.lastPathComponent.hasPrefix(".portavoz-launch-diagnostics-")
        }
        XCTAssertFalse(leavesHiddenStage)
    }

    func testSimulatedOpenFailureRequiresDisposableStore() {
        let production = AppStorageIsolationPolicy(
            arguments: ["Portavoz", "-simulate-database-open-failure"])
        let disposable = AppStorageIsolationPolicy(
            arguments: [
                "Portavoz", "-use-temp-store",
                "-simulate-database-open-failure"
            ])

        XCTAssertFalse(production.simulatesDatabaseOpenFailure)
        XCTAssertTrue(disposable.simulatesDatabaseOpenFailure)
    }

    func testImplicitDisposableDatabaseIdentityDoesNotDriftAcrossRetry() async throws {
        let model = AppLaunchModel(
            arguments: ["Portavoz", "-use-temp-store"],
            environment: [:],
            servicesFactory: { throw LaunchTestError(message: "failure") })
        guard case let .databaseUnavailable(firstFailure) = model.phase else {
            return XCTFail("Expected a failed launch")
        }

        await model.retry()

        guard case let .databaseUnavailable(secondFailure) = model.phase else {
            return XCTFail("Expected retry to preserve the failed state")
        }
        XCTAssertEqual(secondFailure.databaseURL, firstFailure.databaseURL)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PortavozLaunchModel-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false)
        return url
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private struct LaunchTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
