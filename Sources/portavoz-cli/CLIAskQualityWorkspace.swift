import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

/// One disposable corpus lifetime for both canonical quality and attribution.
/// Preparation remains outside observation; neither command reads user data.
struct AskQualityWorkspace: Sendable {
    let store: MeetingStore
    let mapping: AskQualityCorpusMapping
    let runtime: any SemanticEmbeddingRuntimeClient

    static func withCorpus<Result: Sendable>(
        fixture: AskQualityFixture,
        retrievalUnit: AskQualityRetrievalUnit,
        operation: @Sendable (Self) async throws -> Result
    ) async throws -> Result {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "portavoz-ask-quality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(databaseURL: root.appendingPathComponent("quality.sqlite"))
        let mapping = try await AskQualityCorpusMapping.seed(
            fixture: fixture, store: store, retrievalUnit: retrievalUnit)
        let runtime = CLISemanticEmbeddingRuntime()
        return try await operation(Self(store: store, mapping: mapping, runtime: runtime))
    }
}
