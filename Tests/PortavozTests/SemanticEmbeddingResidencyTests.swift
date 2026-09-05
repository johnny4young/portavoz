import ApplicationKit
import Foundation
import PortavozCore
import XCTest
@testable import portavoz_app

final class SemanticEmbeddingResidencyTests: XCTestCase {
    func testConcurrentBorrowersShareOneLoadAndHoldExactUseLeases() async throws {
        let prepareGate = SemanticEmbeddingTestGate()
        let operationGate = SemanticEmbeddingTestGate()
        let model = SemanticEmbeddingTestModel(prepareGate: prepareGate)
        let factory = SemanticEmbeddingTestFactory(models: [model])
        let residency = AppModelResidencyLedger()
        let runtime = AppSemanticEmbeddingRuntime(
            residency: residency,
            telemetry: .disabled,
            makeModel: factory.make)

        let first = Task {
            try await runtime.withPreparedEmbedding(
                allowAssetDownload: false
            ) { embedder in
                _ = try await embedder.vectors(for: ["first"])
                await operationGate.wait()
                return 1
            }
        }
        try await waitUntil {
            await model.prepareCount == 1
        }

        let second = Task {
            try await runtime.withPreparedEmbedding(
                allowAssetDownload: false
            ) { embedder in
                _ = try await embedder.vectors(for: ["second"])
                await operationGate.wait()
                return 2
            }
        }
        await prepareGate.open()
        try await waitUntil {
            residency.record(
                for: .semanticEmbedding
            ).activeUseCount == 2
        }

        XCTAssertEqual(factory.makeCount, 1)
        let prepareCount = await model.prepareCount
        XCTAssertEqual(prepareCount, 1)
        let releasedWhileBusy = await runtime.release()
        XCTAssertFalse(releasedWhileBusy)

        await operationGate.open()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual([firstResult, secondResult], [1, 2])
        XCTAssertEqual(
            residency.record(
                for: .semanticEmbedding
            ).activeUseCount,
            0)
        let releasedAfterUse = await runtime.release()
        XCTAssertTrue(releasedAfterUse)
        XCTAssertEqual(
            residency.record(for: .semanticEmbedding).status,
            .unloaded)
    }

    func testFailedLoadReturnsFamilyToUnloadedAndAllowsRetry() async throws {
        let failed = SemanticEmbeddingTestModel(prepareError: .failed)
        let recovered = SemanticEmbeddingTestModel()
        let factory = SemanticEmbeddingTestFactory(
            models: [failed, recovered])
        let residency = AppModelResidencyLedger()
        let runtime = AppSemanticEmbeddingRuntime(
            residency: residency,
            telemetry: .disabled,
            makeModel: factory.make)

        do {
            _ = try await runtime.withPreparedEmbedding(
                allowAssetDownload: true
            ) { _ in 1 }
            XCTFail("Expected the first embedding load to fail")
        } catch {
            XCTAssertEqual(
                error as? SemanticEmbeddingTestError,
                .failed)
        }
        XCTAssertEqual(
            residency.record(for: .semanticEmbedding).status,
            .unloaded)

        let result = try await runtime.withPreparedEmbedding(
            allowAssetDownload: true
        ) { embedder in
            try await embedder.vectors(for: ["recovered"]).count
        }

        XCTAssertEqual(result, 1)
        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(
            residency.record(for: .semanticEmbedding).status,
            .resident)
        XCTAssertEqual(
            residency.record(
                for: .semanticEmbedding
            ).activeUseCount,
            0)
    }

    func testPreparationCanWarmRuntimeWithoutClaimingAnActiveUse() async throws {
        let model = SemanticEmbeddingTestModel()
        let factory = SemanticEmbeddingTestFactory(models: [model])
        let residency = AppModelResidencyLedger()
        let runtime = AppSemanticEmbeddingRuntime(
            residency: residency,
            telemetry: .disabled,
            makeModel: factory.make)

        try await runtime.prepare(allowAssetDownload: false)

        let record = residency.record(for: .semanticEmbedding)
        XCTAssertEqual(record.status, .resident)
        XCTAssertEqual(record.activeUseCount, 0)
        XCTAssertEqual(factory.makeCount, 1)
        let prepareCount = await model.prepareCount
        XCTAssertEqual(prepareCount, 1)
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for semantic residency state")
    }
}

private enum SemanticEmbeddingTestError: Error {
    case failed
}

private actor SemanticEmbeddingTestModel: SemanticEmbeddingModel {
    private let prepareGate: SemanticEmbeddingTestGate?
    private let prepareError: SemanticEmbeddingTestError?
    private(set) var prepareCount = 0

    init(
        prepareGate: SemanticEmbeddingTestGate? = nil,
        prepareError: SemanticEmbeddingTestError? = nil
    ) {
        self.prepareGate = prepareGate
        self.prepareError = prepareError
    }

    var hasAvailableAssets: Bool { true }

    func prepare(allowAssetDownload _: Bool) async throws {
        prepareCount += 1
        if let prepareGate {
            await prepareGate.wait()
        }
        if let prepareError {
            throw prepareError
        }
    }

    func vectors(for texts: [String]) -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}

private actor SemanticEmbeddingTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = continuations
        self.continuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class SemanticEmbeddingTestFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [any SemanticEmbeddingModel]
    private var count = 0

    init(models: [any SemanticEmbeddingModel]) {
        self.models = models
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func make() throws -> any SemanticEmbeddingModel {
        lock.lock()
        defer { lock.unlock() }
        guard !models.isEmpty else {
            throw SemanticEmbeddingTestError.failed
        }
        count += 1
        return models.removeFirst()
    }
}
