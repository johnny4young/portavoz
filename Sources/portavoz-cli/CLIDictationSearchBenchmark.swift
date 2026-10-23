import ApplicationKit
import CryptoKit
import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

struct DictationSearchFixture: Decodable {
    struct Dictation: Decodable {
        let id: UUID
        let createdAt: Date
        let applicationName: String
        let text: String
    }

    struct Query: Decodable {
        let id: UUID
        let text: String
    }

    let kind: String
    let dictations: [Dictation]
    let queries: [Query]
}

/// Runs the shipped lexical retrieval and a cosine scan over normalized vectors
/// in a disposable store; the user's library is never opened.
enum DictationSearchBenchmark {
    static let resultLimit = 12

    static func observe(
        fixtureData: Data,
        embedding: any SemanticTextEmbedding,
        build: String,
        commit: String,
        scales: [Int],
        rewrites: Bool = DictationSearchExpansion.isAvailable
    ) async throws -> DictationSearchObservations {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let fixture = try? decoder.decode(DictationSearchFixture.self, from: fixtureData),
              fixture.kind == "dictation-search-fixture", !fixture.dictations.isEmpty, !fixture.queries.isEmpty
        else { throw DictationSearchBenchmarkError.invalidFixture }
        let now = (fixture.dictations.map(\.createdAt).max() ?? Date()).addingTimeInterval(3_600)
        let corpus = try await Corpus.seed(fixture.dictations, now: now)
        let embedded = try await Embedded.make(fixture.dictations, embedding: embedding)

        let context = QueryContext(
            corpus: corpus, embedded: embedded, embedding: embedding, rewrites: rewrites, now: now)
        var timings = Timings()
        var queries: [DictationSearchObservations.Query] = []
        for query in fixture.queries {
            queries.append(try await observe(query, in: context, timings: &timings))
        }
        var scaleRows: [DictationSearchObservations.Scale] = []
        for size in scales {
            scaleRows.append(try await scale(
                size, fixture: fixture, vectors: embedded.vectors, embedding: embedding, now: now))
        }
        let profile = await embedding.semanticEmbeddingProfile()
        return DictationSearchObservations(
            fixtureSHA256: SHA256.hash(data: fixtureData).map { String(format: "%02x", $0) }.joined(),
            build: build,
            commit: commit,
            embeddingProfileFingerprint: profile.fingerprint,
            dimension: embedded.vectors[0].count,
            queries: queries,
            resources: .init(
                dictationCount: fixture.dictations.count,
                embedMilliseconds: percentiles(embedded.times),
                lexicalQueryMilliseconds: percentiles(timings.lexical),
                semanticQueryMilliseconds: percentiles(timings.semantic),
                queriesWithParsedFilters: timings.parsedFilters,
                expansionMeetingMilliseconds: timings.rewrite.isEmpty ? nil : percentiles(timings.rewrite),
                expansionDictationMilliseconds: timings.synonym.isEmpty ? nil : percentiles(timings.synonym),
                expansionDictationFailures: timings.synonymFailures,
                scale: scaleRows))
    }

    private struct Timings {
        var lexical: [Double] = []
        var semantic: [Double] = []
        var rewrite: [Double] = []
        var synonym: [Double] = []
        var synonymFailures = 0
        var parsedFilters = 0
    }

    private struct Embedded {
        let vectors: [[Float]]
        let centered: [[Float]]
        let mean: [Float]
        let ids: [String]
        let times: [Double]

        static func make(
            _ dictations: [DictationSearchFixture.Dictation], embedding: any SemanticTextEmbedding
        ) async throws -> Self {
            var vectors: [[Float]] = []
            var times: [Double] = []
            for dictation in dictations {
                let started = ContinuousClock.now
                vectors.append(try await vector(for: dictation.text, embedding: embedding))
                times.append(milliseconds(since: started))
            }
            guard vectors.allSatisfy({ $0.count == vectors[0].count }) else {
                throw DictationSearchBenchmarkError.invalidEmbedding
            }
            let mean = meanVector(vectors)
            return Self(
                vectors: vectors, centered: vectors.map { centeredVector($0, mean: mean) }, mean: mean,
                ids: dictations.map(\.id.uuidString), times: times)
        }
    }

    private struct QueryContext {
        let corpus: Corpus
        let embedded: Embedded
        let embedding: any SemanticTextEmbedding
        let rewrites: Bool
        let now: Date
    }

    private static func observe(
        _ query: DictationSearchFixture.Query,
        in context: QueryContext,
        timings: inout Timings
    ) async throws -> DictationSearchObservations.Query {
        let (corpus, embedded, embedding) = (context.corpus, context.embedded, context.embedding)
        let parsed = AskDictationQuestion.parse(
            query.text, applications: corpus.applications, now: context.now, calendar: Corpus.calendar)
        if parsed.period != nil || parsed.applicationName != nil { timings.parsedFilters += 1 }
        var started = ContinuousClock.now
        let lexical = try await corpus.lexical(query.text)
        timings.lexical.append(milliseconds(since: started))
        started = ContinuousClock.now
        let semantic = try await semanticHits(
            query.text, vectors: embedded.vectors, ids: embedded.ids, embedding: embedding)
        timings.semantic.append(milliseconds(since: started))
        let centered = try await semanticHits(
            query.text, vectors: embedded.centered, ids: embedded.ids, embedding: embedding, mean: embedded.mean)
        started = ContinuousClock.now
        let shipped = context.rewrites ? try await corpus.shipped(query.text) : nil
        if shipped != nil { timings.rewrite.append(milliseconds(since: started)) }
        started = ContinuousClock.now
        let synonyms = context.rewrites ? await DictationSearchExpansion.dictation(query.text) : nil
        if let synonyms {
            timings.synonym.append(milliseconds(since: started))
            if synonyms.isEmpty { timings.synonymFailures += 1 }
        }
        return .init(
            id: query.id.uuidString, lexical: lexical, semantic: semantic, semanticCentered: centered,
            lexicalExpandedMeeting: shipped,
            lexicalExpandedDictation: try await synonyms.asyncMap { try await corpus.expanded(query.text, [$0]) })
    }

    /// The fixture replicated to `size` dictations: lexical in a store of that
    /// size, semantic as a scan over that many copied vectors.
    private static func scale(
        _ size: Int,
        fixture: DictationSearchFixture,
        vectors: [[Float]],
        embedding: any SemanticTextEmbedding,
        now: Date
    ) async throws -> DictationSearchObservations.Scale {
        let replicas = (0..<size).map { index in
            let source = fixture.dictations[index % fixture.dictations.count]
            return DictationSearchFixture.Dictation(
                id: UUID(), createdAt: now.addingTimeInterval(-Double(index + 1)),
                applicationName: source.applicationName, text: source.text)
        }
        let corpus = try await Corpus.seed(replicas, now: now)
        let scaledVectors = (0..<size).map { vectors[$0 % vectors.count] }
        let scaledIDs = replicas.map(\.id.uuidString)
        var lexicalTimes: [Double] = []
        var semanticTimes: [Double] = []
        for query in fixture.queries {
            var started = ContinuousClock.now
            _ = try await corpus.lexical(query.text)
            lexicalTimes.append(milliseconds(since: started))
            started = ContinuousClock.now
            _ = try await semanticHits(query.text, vectors: scaledVectors, ids: scaledIDs, embedding: embedding)
            semanticTimes.append(milliseconds(since: started))
        }
        return .init(
            dictations: size,
            lexicalP95Milliseconds: percentiles(lexicalTimes).p95,
            semanticP95Milliseconds: percentiles(semanticTimes).p95,
            vectorBytes: size * (vectors.first?.count ?? 0) * MemoryLayout<Float>.size)
    }

    private static func semanticHits(
        _ question: String,
        vectors: [[Float]],
        ids: [String],
        embedding: any SemanticTextEmbedding,
        mean: [Float]? = nil
    ) async throws -> [DictationSearchObservations.Hit] {
        let raw = try await vector(for: question, embedding: embedding)
        let query = mean.map { centeredVector(raw, mean: $0) } ?? raw
        guard query.count == vectors.first?.count else { throw DictationSearchBenchmarkError.invalidEmbedding }
        var scored: [(index: Int, similarity: Float)] = []
        scored.reserveCapacity(vectors.count)
        for (index, candidate) in vectors.enumerated() {
            var dot: Float = 0
            for position in candidate.indices { dot += candidate[position] * query[position] }
            scored.append((index, dot))
        }
        let top = scored.sorted {
            $0.similarity != $1.similarity ? $0.similarity > $1.similarity : ids[$0.index] < ids[$1.index]
        }.prefix(resultLimit)
        return top.map { .init(id: ids[$0.index], similarity: (Double($0.similarity) * 10_000).rounded() / 10_000) }
    }

    static func meanVector(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors { for index in vector.indices { sum[index] += vector[index] } }
        return sum.map { $0 / Float(vectors.count) }
    }

    /// Removes the direction every vector shares, so similarity reflects what differs.
    static func centeredVector(_ vector: [Float], mean: [Float]) -> [Float] {
        let shifted = zip(vector, mean).map { $0 - $1 }
        let norm = shifted.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? shifted.map { $0 / norm } : shifted
    }

    private static func vector(for text: String, embedding: any SemanticTextEmbedding) async throws -> [Float] {
        guard let vector = try await embedding.vectors(for: [text]).first, !vector.isEmpty,
              vector.allSatisfy(\.isFinite)
        else { throw DictationSearchBenchmarkError.invalidEmbedding }
        return vector
    }

    static func percentiles(_ values: [Double]) -> DictationSearchObservations.Percentiles {
        let sorted = values.sorted()
        func at(_ quantile: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, max(0, Int((quantile * Double(sorted.count)).rounded(.up)) - 1))
            return (sorted[index] * 1_000).rounded() / 1_000
        }
        return .init(p50: at(0.5), p95: at(0.95))
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }

    /// One disposable store with the history on: the word search alone, and the
    /// shipped Ask retrieval that adds on-device rewrites.
    private struct Corpus {
        static let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            return calendar
        }()

        let retrieval: LocalAskDictationRetrieval
        let shippedRetrieval: LocalAskDictationRetrieval
        let applications: [String]
        let store: MeetingStore
        let now: Date

        static func seed(_ dictations: [DictationSearchFixture.Dictation], now: Date) async throws -> Self {
            let store = try MeetingStore.inMemory()
            _ = try await store.setDictationHistoryPolicy(
                isEnabled: true, keepsOriginal: false, retentionDays: 90, at: now)
            for dictation in dictations {
                _ = try await store.recordDictation(
                    DictationRecord(
                        id: DictationRecordID(rawValue: dictation.id), createdAt: dictation.createdAt,
                        duration: 2, text: dictation.text, originalText: nil, mode: .literal, language: nil,
                        engine: "benchmark", applicationName: dictation.applicationName,
                        applicationBundleID: nil, delivery: .verified),
                    admittedGeneration: 0, at: now)
            }
            return Self(
                retrieval: LocalAskDictationRetrieval(
                    store: store, rewriter: AskQualityNoExpansion(), now: { now }, calendar: calendar),
                shippedRetrieval: LocalAskDictationRetrieval(store: store, now: { now }, calendar: calendar),
                applications: try await store.dictationApplications(),
                store: store,
                now: now)
        }

        /// The shipped word search with the rewrites' content words added as variants.
        func expanded(_ question: String, _ rewrites: [String]) async throws -> [String] {
            func words(_ text: String) -> String {
                AskDictationQuestion.parse(text, applications: applications, now: now, calendar: Self.calendar)
                    .searchWords.joined(separator: " ")
            }
            let base = Array(BilingualSearchQueryExpander().expand(words(question)).prefix(3))
            let queries = (base + rewrites.map(words)).filter { !$0.isEmpty }
            guard !queries.isEmpty,
                  let records = try await store.dictationRecordsForAsk(matchingAny: queries, limit: 24)
            else { return [] }
            return records.prefix(DictationSearchBenchmark.resultLimit).map(\.id.rawValue.uuidString)
        }

        func lexical(_ question: String) async throws -> [String] {
            try await ids(retrieval.retrieve(question: question, limit: DictationSearchBenchmark.resultLimit))
        }

        func shipped(_ question: String) async throws -> [String] {
            try await ids(shippedRetrieval.retrieve(question: question, limit: DictationSearchBenchmark.resultLimit))
        }

        private func ids(_ evidence: AskDictationEvidence) -> [String] {
            switch evidence {
            case .historyOff: []
            case .found(let citations), .listed(let citations, _): citations.map(\.dictationID.rawValue.uuidString)
            }
        }
    }
}

/// On-device rewrites for the benchmark; nil when Foundation Models is unavailable.
enum DictationSearchExpansion {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return false }
        return FoundationModelSummaryProvider.unavailabilityReason() == nil
        #else
        return false
        #endif
    }

    /// Empty when the model refused or failed for this question, as the app would fall back to words.
    static func dictation(_ question: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), FoundationModelSummaryProvider.unavailabilityReason() == nil else {
            return nil
        }
        return (try? await RAGAnswerer().expandDictationQuery(question)) ?? ""
        #else
        return nil
        #endif
    }
}

private extension Optional {
    func asyncMap<Value>(_ transform: (Wrapped) async throws -> Value) async rethrows -> Value? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
