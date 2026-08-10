import AppIntents
import CoreSpotlight
import CryptoKit
import Foundation
import OSLog
import PortavozCore
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

    enum IndexMode: String, Sendable {
        /// The deployment-floor fallback keeps released meeting search on
        /// systems predating App-Entity indexing.
        case meetingDocuments = "meeting-documents-v1"
        /// Sequoia and later publish all three narrow native entity types.
        case appEntities = "app-entities-v1"
    }

    static let domain = "app.portavoz.meetings"
    static let indexName = "app.portavoz.search.v3"
    static let legacyIndexName = "app.portavoz.meetings.v2"
    static let batchSize = 500
    static var indexingAvailable: Bool { CSSearchableIndex.isIndexingAvailable() }

    private let store: MeetingStore
    private let backend: any SpotlightIndexBackend
    private let legacyCleanupState: any SpotlightLegacyCleanupState
    private let enabled: Bool
    private let debounce: Duration
    private let retryDelays: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void
    private let telemetry: ResourceWorkloadTelemetry
    private let logger = Logger(subsystem: "app.portavoz", category: "Spotlight")

    private var generation = 0
    private var worker: Task<Void, Never>?
    /// Both pre-v3 indexes are migration concerns, not recurring library
    /// work. Retain retry-on-failure, then stop waking Core Spotlight.
    private var legacyCleanupComplete = false
    private(set) var status: Status = .idle

    init(
        store: MeetingStore,
        enabled: Bool,
        backend: (any SpotlightIndexBackend)? = nil,
        legacyCleanupState: (any SpotlightLegacyCleanupState)? = nil,
        debounce: Duration = .milliseconds(250),
        retryDelays: [Duration] = [.seconds(1), .seconds(5)],
        telemetry: ResourceWorkloadTelemetry = .disabled,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.store = store
        self.enabled = enabled
        self.backend = backend ?? Self.productionBackend()
        self.legacyCleanupState =
            legacyCleanupState ?? UserDefaultsSpotlightLegacyCleanupState()
        self.debounce = debounce
        self.retryDelays = retryDelays
        self.telemetry = telemetry
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

            let span = telemetry.begin(ResourceWorkloadDescriptor(
                workloadClass: .maintenance,
                kind: .searchIndex,
                operation: .execute))
            do {
                try await reconcile()
                attempt = 0
                telemetry.finish(span, outcome: .completed)
                guard targetGeneration == generation else { continue }
                finish(status: .idle)
                return
            } catch is CancellationError {
                telemetry.finish(span, outcome: .cancelled)
                finish(status: .idle)
                return
            } catch {
                telemetry.finish(span, outcome: .failed)
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

    private func reconcile() async throws {
        status = .projecting
        let snapshot: SpotlightIndexSnapshot
        switch backend.mode {
        case .meetingDocuments:
            snapshot = SpotlightIndexSnapshot(
                meetings: try await store.spotlightDocuments(),
                people: [],
                commitments: [])
        case .appEntities:
            snapshot = try await store.spotlightIndexSnapshot()
        }
        let clientState = Self.clientState(for: snapshot, mode: backend.mode)
        status = .publishing
        if try await backend.lastClientState() != clientState {
            try await backend.replace(snapshot, clientState: clientState)
        }
        // Cleanup runs only after v3 is ready. A durable marker prevents later
        // reconciliations and future launches from repeating the migration.
        guard !legacyCleanupComplete else { return }
        if await legacyCleanupState.isComplete() {
            legacyCleanupComplete = true
        } else {
            try await backend.removeLegacyItems()
            await legacyCleanupState.markComplete()
            legacyCleanupComplete = true
        }
    }

    private func finish(status: Status) {
        self.status = status
        worker = nil
    }

    static func clientState(
        for snapshot: SpotlightIndexSnapshot,
        mode: IndexMode
    ) -> Data {
        var hasher = SHA256()
        update(&hasher, string: mode.rawValue)
        for document in snapshot.meetings {
            update(&hasher, string: document.meetingID.rawValue.uuidString)
            update(&hasher, string: document.title)
            update(&hasher, date: document.startedAt)
            update(&hasher, string: document.contentDescription)
            if mode == .appEntities {
                update(&hasher, string: SpotlightEntityPresentation.meetingDate(
                    document.startedAt))
            }
        }
        if mode == .appEntities {
            for person in snapshot.people {
                update(&hasher, string: person.personID.rawValue.uuidString)
                update(&hasher, string: person.preferredName)
            }
            for commitment in snapshot.commitments {
                update(&hasher, string: commitment.commitmentID.rawValue.uuidString)
                update(&hasher, string: commitment.title)
                update(&hasher, optionalDate: commitment.dueAt)
                update(&hasher, string: SpotlightEntityPresentation.commitmentDueDate(
                    commitment.dueAt) ?? "")
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let personCount = mode == .appEntities ? snapshot.people.count : 0
        let commitmentCount = mode == .appEntities ? snapshot.commitments.count : 0
        let header = [
            mode.rawValue,
            String(snapshot.meetings.count),
            String(personCount),
            String(commitmentCount)
        ].joined(separator: ":")
        return Data("\(header):\(digest)".utf8)
    }

    private static func productionBackend() -> any SpotlightIndexBackend {
        if #available(macOS 15.0, *) {
            return CoreSpotlightAppEntityIndexBackend()
        }
        return CoreSpotlightMeetingDocumentIndexBackend()
    }

    private static func update(_ hasher: inout SHA256, string: String) {
        let data = Data(string.utf8)
        var count = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    private static func update(_ hasher: inout SHA256, date: Date) {
        var bits = date.timeIntervalSinceReferenceDate.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { hasher.update(bufferPointer: $0) }
    }

    private static func update(_ hasher: inout SHA256, optionalDate: Date?) {
        update(&hasher, string: optionalDate == nil ? "nil" : "date")
        if let optionalDate {
            update(&hasher, date: optionalDate)
        }
    }
}

protocol SpotlightIndexBackend: Sendable {
    var mode: SpotlightIndexer.IndexMode { get }
    func lastClientState() async throws -> Data?
    func replace(_ snapshot: SpotlightIndexSnapshot, clientState: Data) async throws
    func removeLegacyItems() async throws
}

protocol SpotlightLegacyCleanupState: Sendable {
    func isComplete() async -> Bool
    func markComplete() async
}

private actor UserDefaultsSpotlightLegacyCleanupState: SpotlightLegacyCleanupState {
    private static let key = "spotlightLegacyIndexesV3CleanupComplete"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isComplete() -> Bool {
        defaults.bool(forKey: Self.key)
    }

    func markComplete() {
        defaults.set(true, forKey: Self.key)
    }
}

private actor CoreSpotlightMeetingDocumentIndexBackend: SpotlightIndexBackend {
    nonisolated let mode: SpotlightIndexer.IndexMode = .meetingDocuments
    private let index = CSSearchableIndex(
        name: SpotlightIndexer.indexName,
        protectionClass: .complete)

    func lastClientState() async throws -> Data? {
        return try await index.fetchLastClientState()
    }

    func replace(_ snapshot: SpotlightIndexSnapshot, clientState: Data) async throws {
        index.beginBatch()
        do {
            try await index.deleteAllSearchableItems()
            for batch in snapshot.meetings.batches(of: SpotlightIndexer.batchSize) {
                try await index.indexSearchableItems(batch.map(Self.searchableItem))
            }
        } catch {
            try? await index.endBatch(withClientState: Data("incomplete".utf8))
            throw error
        }
        try await index.endBatch(withClientState: clientState)
    }

    func removeLegacyItems() async throws {
        try await removeLegacySpotlightItems()
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

@available(macOS 15.0, *)
private actor CoreSpotlightAppEntityIndexBackend: SpotlightIndexBackend {
    nonisolated let mode: SpotlightIndexer.IndexMode = .appEntities

    func lastClientState() async throws -> Data? {
        let index = CSSearchableIndex(
            name: SpotlightIndexer.indexName,
            protectionClass: .complete)
        return try await index.fetchLastClientState()
    }

    func replace(_ snapshot: SpotlightIndexSnapshot, clientState: Data) async throws {
        // AppIntents' async CSSearchableIndex extensions do not annotate the
        // reference as Sendable. Keep it task-local instead of actor state so
        // strict Swift 6 never transfers an actor-isolated framework object.
        let index = CSSearchableIndex(
            name: SpotlightIndexer.indexName,
            protectionClass: .complete)
        index.beginBatch()
        do {
            try await index.deleteAllSearchableItems()
            for batch in snapshot.meetings.batches(of: SpotlightIndexer.batchSize) {
                try await index.indexAppEntities(
                    batch.map(SpotlightAppEntityFactory.meeting))
            }
            for batch in snapshot.people.batches(of: SpotlightIndexer.batchSize) {
                try await index.indexAppEntities(
                    batch.map(SpotlightAppEntityFactory.person))
            }
            for batch in snapshot.commitments.batches(of: SpotlightIndexer.batchSize) {
                try await index.indexAppEntities(
                    batch.map(SpotlightAppEntityFactory.commitment))
            }
        } catch {
            try? await index.endBatch(withClientState: Data("incomplete".utf8))
            throw error
        }
        try await index.endBatch(withClientState: clientState)
    }

    func removeLegacyItems() async throws {
        try await removeLegacySpotlightItems()
    }
}

@available(macOS 15.0, *)
enum SpotlightAppEntityFactory {
    static func meeting(_ document: SpotlightDocument) -> PortavozMeetingEntity {
        PortavozMeetingEntity(
            id: document.meetingID.rawValue.uuidString,
            title: document.title,
            dateDescription: SpotlightEntityPresentation.meetingDate(document.startedAt),
            startedAt: document.startedAt,
            searchableContent: document.contentDescription)
    }

    static func person(_ document: SpotlightPersonDocument) -> PortavozPersonEntity {
        PortavozPersonEntity(
            id: document.personID.rawValue.uuidString,
            name: document.preferredName)
    }

    static func commitment(
        _ document: SpotlightCommitmentDocument
    ) -> PortavozCommitmentEntity {
        PortavozCommitmentEntity(
            id: document.commitmentID.rawValue.uuidString,
            title: document.title,
            dueDescription: SpotlightEntityPresentation.commitmentDueDate(document.dueAt),
            dueAt: document.dueAt)
    }
}

private enum SpotlightEntityPresentation {
    static func meetingDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func commitmentDueDate(_ date: Date?) -> String? {
        date?.formatted(date: .abbreviated, time: .omitted)
    }
}

private func removeLegacySpotlightItems() async throws {
    let legacyIndex = CSSearchableIndex(
        name: SpotlightIndexer.legacyIndexName,
        protectionClass: .complete)
    legacyIndex.beginBatch()
    do {
        try await legacyIndex.deleteAllSearchableItems()
    } catch {
        try? await legacyIndex.endBatch(withClientState: Data("incomplete".utf8))
        throw error
    }
    // A deliberately foreign state makes an older app rebuild instead of
    // believing its now-empty v2 index is current after a downgrade.
    try await legacyIndex.endBatch(withClientState: Data("migrated-to-v3".utf8))
    try await CSSearchableIndex.default().deleteSearchableItems(
        withDomainIdentifiers: [SpotlightIndexer.domain])
}

private extension Array {
    func batches(of size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { start in
            self[start..<Swift.min(start + size, count)]
        }
    }
}
