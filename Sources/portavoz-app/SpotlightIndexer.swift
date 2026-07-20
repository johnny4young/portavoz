import CoreSpotlight
import CryptoKit
import Foundation
import OSLog
import StorageKit
import UniformTypeIdentifiers

/// Process-scoped Spotlight reconciliation. Requests coalesce, projection is
/// one consistent SQLite snapshot, and a named protected index keeps crash
/// recovery state. Nothing here is owned by a SwiftUI window.
actor SpotlightIndexer {
    enum Status: Equatable, Sendable {
        case idle
        case scheduled
        case projecting
        case publishing
        case retrying(attempt: Int)
        case failed(attempts: Int)
    }

    static let domain = "app.portavoz.meetings"
    static let indexName = "app.portavoz.meetings.v2"
    static let batchSize = 500
    static var indexingAvailable: Bool { CSSearchableIndex.isIndexingAvailable() }

    private let store: MeetingStore
    private let backend: any SpotlightIndexBackend
    private let enabled: Bool
    private let debounce: Duration
    private let retryDelays: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void
    private let logger = Logger(subsystem: "app.portavoz", category: "Spotlight")

    private var generation = 0
    private var worker: Task<Void, Never>?
    private(set) var status: Status = .idle

    init(
        store: MeetingStore,
        enabled: Bool,
        backend: (any SpotlightIndexBackend)? = nil,
        debounce: Duration = .milliseconds(250),
        retryDelays: [Duration] = [.seconds(1), .seconds(5)],
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.store = store
        self.enabled = enabled
        self.backend = backend ?? CoreSpotlightIndexBackend()
        self.debounce = debounce
        self.retryDelays = retryDelays
        self.sleep = sleep
    }

    func requestReindex() {
        guard enabled else { return }
        generation += 1
        guard worker == nil else { return }
        worker = Task { await runWorker() }
    }

    /// Deterministic synchronization point for unit tests and benchmarks.
    func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    private func runWorker() async {
        var attempt = 0
        var attemptedGeneration = generation

        while !Task.isCancelled {
            let targetGeneration = generation
            if targetGeneration != attemptedGeneration {
                attempt = 0
                attemptedGeneration = targetGeneration
            }
            status = .scheduled
            do {
                try await sleep(debounce)
            } catch {
                finish(status: .idle)
                return
            }
            guard targetGeneration == generation else { continue }

            do {
                status = .projecting
                let documents = try await store.spotlightDocuments()
                let clientState = Self.clientState(for: documents)
                status = .publishing
                if try await backend.lastClientState() != clientState {
                    try await backend.replace(documents, clientState: clientState)
                }
                // The released implementation used the default prototype
                // index. Cleanup runs only after the protected index is ready
                // and repeats harmlessly until it succeeds.
                try await backend.removeLegacyDefaultItems()
                attempt = 0
                guard targetGeneration == generation else { continue }
                finish(status: .idle)
                return
            } catch is CancellationError {
                finish(status: .idle)
                return
            } catch {
                attempt += 1
                logger.error("Spotlight reconciliation failed; attempt=\(attempt, privacy: .public)")
                guard attempt <= retryDelays.count else {
                    finish(status: .failed(attempts: attempt))
                    return
                }
                status = .retrying(attempt: attempt)
                do {
                    try await sleep(retryDelays[attempt - 1])
                } catch {
                    finish(status: .idle)
                    return
                }
            }
        }
        finish(status: .idle)
    }

    private func finish(status: Status) {
        self.status = status
        worker = nil
    }

    static func clientState(for documents: [SpotlightDocument]) -> Data {
        var hasher = SHA256()
        for document in documents {
            update(&hasher, string: document.meetingID.rawValue.uuidString)
            update(&hasher, string: document.title)
            var startedAt = document.startedAt.timeIntervalSinceReferenceDate.bitPattern.littleEndian
            withUnsafeBytes(of: &startedAt) { hasher.update(bufferPointer: $0) }
            update(&hasher, string: document.contentDescription)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Data("v1:\(documents.count):\(digest)".utf8)
    }

    private static func update(_ hasher: inout SHA256, string: String) {
        let data = Data(string.utf8)
        var count = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }
}

protocol SpotlightIndexBackend: Sendable {
    func lastClientState() async throws -> Data?
    func replace(_ documents: [SpotlightDocument], clientState: Data) async throws
    func removeLegacyDefaultItems() async throws
}

private actor CoreSpotlightIndexBackend: SpotlightIndexBackend {
    private let index = CSSearchableIndex(
        name: SpotlightIndexer.indexName,
        protectionClass: .complete)

    func lastClientState() async throws -> Data? {
        try await index.fetchLastClientState()
    }

    func replace(_ documents: [SpotlightDocument], clientState: Data) async throws {
        index.beginBatch()
        do {
            try await index.deleteSearchableItems(
                withDomainIdentifiers: [SpotlightIndexer.domain])
            for start in stride(from: 0, to: documents.count, by: SpotlightIndexer.batchSize) {
                let end = min(start + SpotlightIndexer.batchSize, documents.count)
                let items = documents[start..<end].map(Self.searchableItem)
                try await index.indexSearchableItems(items)
            }
        } catch {
            // Close a partially assembled batch before the actor retries.
            // A non-matching state forces the complete replacement next time.
            try? await index.endBatch(withClientState: Data("incomplete".utf8))
            throw error
        }
        try await index.endBatch(withClientState: clientState)
    }

    func removeLegacyDefaultItems() async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(
            withDomainIdentifiers: [SpotlightIndexer.domain])
    }

    private static func searchableItem(_ document: SpotlightDocument) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = document.title
        attributes.contentCreationDate = document.startedAt
        attributes.contentDescription = document.contentDescription
        return CSSearchableItem(
            uniqueIdentifier: document.meetingID.rawValue.uuidString,
            domainIdentifier: SpotlightIndexer.domain,
            attributeSet: attributes)
    }
}
