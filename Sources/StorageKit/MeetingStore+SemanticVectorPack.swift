import Accelerate
import Foundation
import GRDB
import PortavozCore

struct SemanticPackQuery: Sendable {
    let variantCount: Int
    let flattenedQueries: [Float]
    let dimension: Int
    let expectedBytes: Int
    let profileFingerprint: String
    let limit: Int
}

extension MeetingStore {
    static func semanticPackedCandidates(
        for query: SemanticPackQuery,
        in database: Database,
        cache: SemanticVectorPackCache
    ) throws -> [[SemanticCandidate]]? {
        let state = try cache.lookup(
            profileFingerprint: query.profileFingerprint,
            dimension: query.dimension,
            in: database)
        let pack: SemanticVectorPack
        if let cached = state.pack {
            pack = cached
        } else {
            let built = try buildSemanticVectorPack(
                profileFingerprint: query.profileFingerprint,
                dimension: query.dimension,
                expectedBytes: query.expectedBytes,
                inProcessGeneration: state.inProcess,
                externalGeneration: state.external,
                in: database)
            cache.store(built, observedDataVersion: state.dataVersion, on: database)
            pack = built
        }

        let variantCount = query.variantCount
        if pack.isEmpty {
            return [[SemanticCandidate]](repeating: [], count: variantCount)
        }

        let scratch = cache.checkoutScratch(
            dimension: query.dimension,
            variantCount: variantCount,
            tileRows: SemanticPackScorer.tileRows)
        let shortlists = SemanticPackScorer.shortlistIndices(
            in: pack,
            flattenedQueries: query.flattenedQueries,
            variantCount: variantCount,
            limit: query.limit,
            scratch: scratch)
        cache.checkinScratch(scratch)

        guard let shortlists else { return nil }
        return try rerankShortlistedCandidates(
            shortlists: shortlists,
            in: pack,
            for: query,
            database: database)
    }

    private static func buildSemanticVectorPack(
        profileFingerprint: String,
        dimension: Int,
        expectedBytes: Int,
        inProcessGeneration: UInt64,
        externalGeneration: UInt64,
        in database: Database
    ) throws -> SemanticVectorPack {
        let scan = try semanticScan(profileFingerprint: profileFingerprint, in: database)
        let rows = try Row.fetchCursor(database, sql: scan.sql, arguments: scan.arguments)
        var builder = SemanticPackBuilder(dimension: dimension, expectedBytes: expectedBytes)
        var traversalOrder = 0
        while let row = try rows.next() {
            let order = traversalOrder
            traversalOrder += 1
            try builder.appendRow(row, order: order)
        }
        return builder.finish(
            profileFingerprint: profileFingerprint,
            inProcessGeneration: inProcessGeneration,
            externalGeneration: externalGeneration)
    }

    private static func rerankShortlistedCandidates(
        shortlists: [[Int]],
        in pack: SemanticVectorPack,
        for query: SemanticPackQuery,
        database: Database
    ) throws -> [[SemanticCandidate]] {
        let blobs = try fetchShortlistedBlobs(
            shortlists: shortlists,
            in: pack,
            profileFingerprint: query.profileFingerprint,
            database: database)
        var candidates = [[SemanticCandidate]](repeating: [], count: shortlists.count)
        for slot in candidates.indices {
            candidates[slot].reserveCapacity(min(query.limit, 64))
        }
        query.flattenedQueries.withUnsafeBufferPointer { queryBuffer in
            let variants = (0..<query.variantCount).map { slot in
                UnsafeBufferPointer(
                    rebasing: queryBuffer[
                        (slot * query.dimension)..<((slot + 1) * query.dimension)])
            }
            for slot in shortlists.indices {
                for idx in shortlists[slot] {
                    guard let source = pack.source(at: idx) else { continue }
                    let key = SemanticCandidateKey(rowID: pack.rowIDs[idx], source: source)
                    guard let blob = blobs[key],
                          let exactScore = semanticDotProduct(
                              blob,
                              query: variants[slot],
                              expectedBytes: query.expectedBytes)
                    else { continue }
                    admit(
                        score: exactScore,
                        order: Int(pack.orders[idx]),
                        rowID: pack.rowIDs[idx],
                        source: source,
                        into: &candidates[slot],
                        limit: query.limit)
                }
            }
        }
        return candidates
    }

    private static func fetchShortlistedBlobs(
        shortlists: [[Int]],
        in pack: SemanticVectorPack,
        profileFingerprint: String,
        database: Database
    ) throws -> [SemanticCandidateKey: Data] {
        var acceptedIDs = Set<Int64>()
        var correctedIDs = Set<Int64>()
        var structuralIDs = Set<Int64>()
        for list in shortlists {
            for idx in list {
                let rowID = pack.rowIDs[idx]
                switch pack.sourceKinds[idx] {
                case 1: correctedIDs.insert(rowID)
                case 2: structuralIDs.insert(rowID)
                default: acceptedIDs.insert(rowID)
                }
            }
        }
        var blobs: [SemanticCandidateKey: Data] = [:]
        blobs.reserveCapacity(acceptedIDs.count + correctedIDs.count + structuralIDs.count)
        try fetchAcceptedEmbeddingBlobs(Array(acceptedIDs), into: &blobs, in: database)
        try fetchCorrectedEmbeddingBlobs(
            Array(correctedIDs), profileFingerprint: profileFingerprint, into: &blobs, in: database)
        try fetchStructuralEmbeddingBlobs(
            Array(structuralIDs), profileFingerprint: profileFingerprint, into: &blobs, in: database)
        return blobs
    }

    private static func fetchAcceptedEmbeddingBlobs(
        _ rowIDs: [Int64],
        into blobs: inout [SemanticCandidateKey: Data],
        in database: Database
    ) throws {
        guard !rowIDs.isEmpty else { return }
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT rowid, embedding
                FROM segment
                WHERE rowid IN (\(databaseQuestionMarks(count: rowIDs.count)))
                  AND embedding IS NOT NULL
                """,
            arguments: StatementArguments(rowIDs))
        for row in rows {
            let rowID: Int64 = row[0]
            if let data: Data = row[1] {
                blobs[SemanticCandidateKey(rowID: rowID, source: .accepted)] = data
            }
        }
    }

    private static func fetchCorrectedEmbeddingBlobs(
        _ rowIDs: [Int64],
        profileFingerprint: String,
        into blobs: inout [SemanticCandidateKey: Data],
        in database: Database
    ) throws {
        guard !rowIDs.isEmpty else { return }
        var arguments = StatementArguments(rowIDs)
        _ = arguments.append(contentsOf: [profileFingerprint])
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT segment.rowid, corrected.correctionID, corrected.embedding
                FROM segmentCorrectedText AS corrected
                JOIN segment ON segment.id = corrected.segmentID
                WHERE segment.rowid IN (\(databaseQuestionMarks(count: rowIDs.count)))
                  AND corrected.embedding IS NOT NULL
                  AND corrected.embeddingFingerprint = ?
                """,
            arguments: arguments)
        for row in rows {
            let rowID: Int64 = row[0]
            let correctionID = try PersistedIdentity.required(
                row[1], table: "segmentCorrectedText", column: "correctionID")
            if let data: Data = row[2] {
                blobs[SemanticCandidateKey(
                    rowID: rowID,
                    source: .corrected(correctionID: correctionID))] = data
            }
        }
    }

    private static func fetchStructuralEmbeddingBlobs(
        _ rowIDs: [Int64],
        profileFingerprint: String,
        into blobs: inout [SemanticCandidateKey: Data],
        in database: Database
    ) throws {
        guard !rowIDs.isEmpty else { return }
        var arguments = StatementArguments(rowIDs)
        _ = arguments.append(contentsOf: [profileFingerprint])
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT rowid, correctionID, embedding
                FROM transcriptStructuralSearchRow
                WHERE rowid IN (\(databaseQuestionMarks(count: rowIDs.count)))
                  AND embedding IS NOT NULL
                  AND embeddingFingerprint = ?
                """,
            arguments: arguments)
        for row in rows {
            let rowID: Int64 = row[0]
            let correctionID = try PersistedIdentity.required(
                row[1], table: "transcriptStructuralSearchRow", column: "correctionID")
            if let data: Data = row[2] {
                blobs[SemanticCandidateKey(
                    rowID: rowID,
                    source: .structural(correctionID: correctionID))] = data
            }
        }
    }
}

private struct SemanticPackBuilder {
    let dimension: Int
    let expectedBytes: Int
    let batchRows = SemanticPackScorer.tileRows
    var stagingFloats: [Float]
    var stagingHalf: [UInt16]
    var stagedCount = 0
    var packedVectors: [UInt16] = []
    var rowIDs: [Int64] = []
    var orders: [Int32] = []
    var sourceKinds: [UInt8] = []
    var correctionIDs: [Int: UUID] = [:]
    var alwaysRerankIndices: [Int] = []

    init(dimension: Int, expectedBytes: Int) {
        self.dimension = dimension
        self.expectedBytes = expectedBytes
        stagingFloats = [Float](repeating: 0, count: batchRows * dimension)
        stagingHalf = [UInt16](repeating: 0, count: batchRows * dimension)
    }

    mutating func appendRow(_ row: Row, order: Int) throws {
        let rowID: Int64 = row[1]
        let source = try MeetingStore.semanticCandidateSource(from: row)
        let dimension = self.dimension
        let expectedBytes = self.expectedBytes
        let stagedIndex = self.stagedCount
        var inspected: (isValid: Bool, exceedsHalfRange: Bool) = (false, false)
        try row.withUnsafeData(atIndex: 0) { blob in
            guard let blob, blob.count == expectedBytes else { return }
            inspected = blob.withUnsafeBytes { rawBuffer in
                stagingFloats.withUnsafeMutableBufferPointer { floatPtr in
                    guard let dst = floatPtr.baseAddress else { return (false, false) }
                    return SemanticPackScorer.inspectVector(
                        rawBuffer,
                        into: dst + stagedIndex * dimension,
                        dimension: dimension)
                }
            }
        }
        guard inspected.isValid else { return }
        let entryIndex = rowIDs.count
        rowIDs.append(rowID)
        orders.append(Int32(clamping: order))
        switch source {
        case .accepted:
            sourceKinds.append(0)
        case .corrected(let id):
            sourceKinds.append(1)
            correctionIDs[entryIndex] = id
        case .structural(let id):
            sourceKinds.append(2)
            correctionIDs[entryIndex] = id
        }
        if inspected.exceedsHalfRange {
            alwaysRerankIndices.append(entryIndex)
        }
        stagedCount += 1
        if stagedCount == batchRows {
            flushStage()
        }
    }

    mutating func finish(
        profileFingerprint: String,
        inProcessGeneration: UInt64,
        externalGeneration: UInt64
    ) -> SemanticVectorPack {
        flushStage()
        return SemanticVectorPack(
            profileFingerprint: profileFingerprint,
            dimension: dimension,
            inProcessGeneration: inProcessGeneration,
            externalGeneration: externalGeneration,
            packedVectors: packedVectors,
            rowIDs: rowIDs,
            orders: orders,
            sourceKinds: sourceKinds,
            correctionIDs: correctionIDs,
            alwaysRerankIndices: alwaysRerankIndices)
    }

    private mutating func flushStage() {
        guard stagedCount > 0 else { return }
        let count = stagedCount * dimension
        stagingFloats.withUnsafeBufferPointer { src in
            stagingHalf.withUnsafeMutableBufferPointer { dst in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                SemanticPackScorer.convertFloatsToHalf(
                    UnsafeBufferPointer(start: srcBase, count: count),
                    into: UnsafeMutableBufferPointer(start: dstBase, count: count))
            }
        }
        packedVectors.append(contentsOf: stagingHalf.prefix(count))
        stagedCount = 0
    }
}
