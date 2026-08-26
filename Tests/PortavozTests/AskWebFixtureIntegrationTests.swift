import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import XCTest

@testable import StorageKit

final class AskWebFixtureIntegrationTests: XCTestCase {
    func testRealGatewayHandlesBilingualEvidenceAndAdversarialFailures() async throws {
        let fixture = try UnitTestWebFixtureProcess.start()
        defer { fixture.stop() }
        let store = try MeetingStore.inMemory()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let retriever = URLSessionAskWebSourceRetrieval(
            gateway: URLSessionDataEgressGateway(
                session: session,
                receiptRecorder: store),
            policy: .loopbackFixture,
            now: { Date(timeIntervalSince1970: 1_787_529_600) })

        let english = try await retriever.retrieve(
            fixture.url("/source/fresh-en"))
        let spanish = try await retriever.retrieve(
            fixture.url("/source/fresh-es"))
        let stale = try await retriever.retrieve(
            fixture.url("/source/stale-en"))
        let undated = try await retriever.retrieve(
            fixture.url("/source/missing-date"))
        let hostile = try await retriever.retrieve(
            fixture.url("/hostile/prompt-injection-en"))

        XCTAssertTrue(english.text.contains("Harbor launches September 14"))
        XCTAssertTrue(spanish.text.contains("Costa se lanza el 18 de septiembre"))
        XCTAssertEqual(english.freshness, .recent)
        XCTAssertEqual(spanish.freshness, .recent)
        XCTAssertEqual(stale.freshness, .stale)
        XCTAssertEqual(undated.freshness, .unknown)
        XCTAssertNil(undated.observedDate)
        XCTAssertTrue(hostile.text.contains("IGNORE PREVIOUS INSTRUCTIONS"))
        XCTAssertTrue(hostile.text.contains("private meeting transcripts"))

        await assertRetrievalError(
            .redirected,
            from: fixture.url("/redirect/fresh-en"),
            using: retriever)
        await assertRetrievalError(
            .providerUnavailable,
            from: fixture.url("/error/provider-down"),
            using: retriever)
        await assertRetrievalError(
            .transport,
            from: fixture.url("/partial/fresh-en"),
            using: retriever)
        await assertRetrievalError(
            .transport,
            from: fixture.url("/transport/disconnect"),
            using: retriever)

        let slow = Task {
            try await retriever.retrieve(fixture.url("/slow/fresh-es"))
        }
        try await Task.sleep(for: .milliseconds(20))
        slow.cancel()
        await XCTAssertThrowsErrorAsync(try await slow.value) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }

        let events = try await store.globalDataEgressEvents()
        XCTAssertEqual(events.count, 10)
        XCTAssertTrue(events.allSatisfy { event in
            event.meetingID == nil
                && event.operation == .webSourceRetrieval
                && event.destinationScope == .localDevice
                && event.destinationHost == "127.0.0.1"
                && event.dataClassification == .publicWebSourceRequest
                && event.consentSource == .explicitWebAsk
                && event.providerID == "127.0.0.1"
                && event.modelID == nil
        })
        let columns = try await store.database.read { database in
            try Set(database.columns(in: "globalDataEgressEvent").map(\.name))
        }
        for forbidden in [
            "url", "path", "query", "question", "body", "text",
            "transcript", "prompt", "answer", "content",
        ] {
            XCTAssertFalse(columns.contains(forbidden), forbidden)
        }
    }

    private func assertRetrievalError(
        _ expected: AskWebRetrievalError,
        from url: URL,
        using retriever: URLSessionAskWebSourceRetrieval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await XCTAssertThrowsErrorAsync(
            try await retriever.retrieve(url),
            { error in
                XCTAssertEqual(
                    error as? AskWebRetrievalError,
                    expected,
                    file: file,
                    line: line)
            },
            file: file,
            line: line)
    }
}

private final class UnitTestWebFixtureProcess: @unchecked Sendable {
    let baseURL: URL

    private let process: Process
    private let readyFile: URL
    private let output: Pipe

    private init(
        baseURL: URL,
        process: Process,
        readyFile: URL,
        output: Pipe
    ) {
        self.baseURL = baseURL
        self.process = process
        self.readyFile = readyFile
        self.output = output
    }

    static func start(timeout: TimeInterval = 30) throws -> UnitTestWebFixtureProcess {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-web-unit-\(UUID().uuidString).json")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            root.appendingPathComponent("scripts/apuntador_web_fixture.py").path,
            "serve",
            "--fixture",
            root.appendingPathComponent(
                "Fixtures/ApuntadorWeb/public-local-v1.json").path,
            "--ready-file",
            readyFile.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline,
              !FileManager.default.fileExists(atPath: readyFile.path),
              process.isRunning {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.isRunning,
              FileManager.default.fileExists(atPath: readyFile.path)
        else {
            let diagnostic = Self.stop(
                process: process,
                readyFile: readyFile,
                output: output)
            throw FixtureError.didNotStart(diagnostic)
        }
        let descriptor: Descriptor
        do {
            descriptor = try JSONDecoder().decode(
                Descriptor.self,
                from: Data(contentsOf: readyFile))
        } catch {
            _ = Self.stop(
                process: process,
                readyFile: readyFile,
                output: output)
            throw FixtureError.invalidDescriptor
        }
        guard descriptor.schemaVersion == 1,
              descriptor.generation == "public-local-v1",
              descriptor.fixtureChecksum.count == 64,
              let baseURL = URL(string: descriptor.baseURL),
              baseURL.host == "127.0.0.1"
        else {
            _ = Self.stop(
                process: process,
                readyFile: readyFile,
                output: output)
            throw FixtureError.invalidDescriptor
        }
        return UnitTestWebFixtureProcess(
            baseURL: baseURL,
            process: process,
            readyFile: readyFile,
            output: output)
    }

    func url(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    func stop(timeout: TimeInterval = 5) {
        _ = Self.stop(
            process: process,
            readyFile: readyFile,
            output: output,
            timeout: timeout)
    }

    private static func stop(
        process: Process,
        readyFile: URL,
        output: Pipe,
        timeout: TimeInterval = 5
    ) -> String {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { process.interrupt() }
        }
        let diagnostic = outputText(from: output)
        try? FileManager.default.removeItem(at: readyFile)
        output.fileHandleForReading.closeFile()
        return diagnostic
    }

    private static func outputText(from pipe: Pipe) -> String {
        String(
            decoding: pipe.fileHandleForReading.availableData,
            as: UTF8.self)
    }
}

private extension UnitTestWebFixtureProcess {
    struct Descriptor: Decodable {
        let schemaVersion: Int
        let generation: String
        let fixtureChecksum: String
        let baseURL: String
    }

    enum FixtureError: Error {
        case didNotStart(String)
        case invalidDescriptor
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
