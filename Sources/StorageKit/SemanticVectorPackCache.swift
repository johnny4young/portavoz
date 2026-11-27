import Accelerate
import Foundation
import GRDB
import PortavozCore
import Synchronization

/// Contiguous `Float16` vector pack paired with exact `Float32` shortlist reranking.
final class SemanticVectorPack: Sendable {
    let profileFingerprint: String
    let dimension: Int
    let inProcessGeneration: UInt64
    let externalGeneration: UInt64
    let packedVectors: [UInt16]
    let rowIDs: [Int64]
    let orders: [Int32]
    let sourceKinds: [UInt8]
    let correctionIDs: [Int: UUID]
    let alwaysRerankIndices: [Int]

    var count: Int { rowIDs.count }
    var isEmpty: Bool { rowIDs.isEmpty }

    init(
        profileFingerprint: String,
        dimension: Int,
        inProcessGeneration: UInt64,
        externalGeneration: UInt64,
        packedVectors: [UInt16],
        rowIDs: [Int64],
        orders: [Int32],
        sourceKinds: [UInt8],
        correctionIDs: [Int: UUID],
        alwaysRerankIndices: [Int]
    ) {
        self.profileFingerprint = profileFingerprint
        self.dimension = dimension
        self.inProcessGeneration = inProcessGeneration
        self.externalGeneration = externalGeneration
        self.packedVectors = packedVectors
        self.rowIDs = rowIDs
        self.orders = orders
        self.sourceKinds = sourceKinds
        self.correctionIDs = correctionIDs
        self.alwaysRerankIndices = alwaysRerankIndices
    }

    func source(at index: Int) -> SemanticEmbeddingCandidate.Source? {
        switch sourceKinds[index] {
        case 1:
            return correctionIDs[index].map { .corrected(correctionID: $0) }
        case 2:
            return correctionIDs[index].map { .structural(correctionID: $0) }
        default:
            return .accepted
        }
    }
}

final class SemanticVectorScratchBuffers {
    var tileFloats: [Float] = []
    var transposedQueries: [Float] = []
    var tileScores: [Float] = []

    func ensureCapacity(dimension: Int, variantCount: Int, tileRows: Int) {
        let tileFloatCount = tileRows * dimension
        if tileFloats.count < tileFloatCount {
            tileFloats = [Float](repeating: 0, count: tileFloatCount)
        }
        let queryCount = dimension * variantCount
        if transposedQueries.count < queryCount {
            transposedQueries = [Float](repeating: 0, count: queryCount)
        }
        let scoreCount = tileRows * variantCount
        if tileScores.count < scoreCount {
            tileScores = [Float](repeating: 0, count: scoreCount)
        }
    }
}

/// Thread-safe cache invalidated on any in-process or cross-process corpus mutation.
final class SemanticVectorPackCache: Sendable {
    final class Observer: TransactionObserver, Sendable {
        private static let watchedTables: Set<String> = [
            "meeting",
            "segment",
            "segmentCorrectedText",
            "transcriptStructuralSearchRow",
            "transcriptCorrection",
            "transcriptCorrectionSearchState"
        ]

        private weak let owner: SemanticVectorPackCache?
        private let pendingMutation = Mutex(false)

        init(owner: SemanticVectorPackCache) {
            self.owner = owner
        }

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            Self.watchedTables.contains(eventKind.tableName)
        }

        func databaseDidChange(with event: DatabaseEvent) {
            _ = event
            pendingMutation.withLock { $0 = true }
        }

        func databaseDidCommit(_ db: Database) {
            _ = db
            let mutated = pendingMutation.withLock { state in
                let value = state
                state = false
                return value
            }
            if mutated {
                owner?.recordInProcessMutation()
            }
        }

        func databaseDidRollback(_ db: Database) {
            _ = db
            pendingMutation.withLock { $0 = false }
        }
    }

    private struct State: @unchecked Sendable {
        var inProcessGeneration: UInt64 = 1
        var externalGeneration: UInt64 = 1
        var seenDataVersions: [ObjectIdentifier: Int64] = [:]
        var pack: SemanticVectorPack?
        var scratchPool: [SemanticVectorScratchBuffers] = []
    }

    private let state = Mutex(State())

    func makeTransactionObserver() -> Observer {
        Observer(owner: self)
    }

    func recordInProcessMutation() {
        state.withLock { current in
            current.inProcessGeneration &+= 1
            current.pack = nil
            current.seenDataVersions.removeAll(keepingCapacity: true)
        }
    }

    func clear() {
        state.withLock { current in
            // Rejects a pack whose build started before the release.
            current.inProcessGeneration &+= 1
            current.pack = nil
            current.seenDataVersions.removeAll()
            current.scratchPool.removeAll()
        }
    }

    struct LookupResult {
        let pack: SemanticVectorPack?
        let inProcess: UInt64
        let external: UInt64
        let dataVersion: Int64
    }

    func lookup(
        profileFingerprint: String,
        dimension: Int,
        in database: Database
    ) throws -> LookupResult {
        let dataVersion = try Int64.fetchOne(database, sql: "PRAGMA data_version") ?? 0
        let connectionID = ObjectIdentifier(database)
        return state.withLock { current in
            if let previous = current.seenDataVersions[connectionID], previous != dataVersion {
                current.seenDataVersions[connectionID] = dataVersion
                if let existing = current.pack, existing.inProcessGeneration == current.inProcessGeneration {
                    current.externalGeneration &+= 1
                    current.pack = nil
                }
            } else if current.seenDataVersions[connectionID] == nil {
                current.seenDataVersions[connectionID] = dataVersion
            }

            if let existing = current.pack,
               existing.profileFingerprint == profileFingerprint,
               existing.dimension == dimension,
               existing.inProcessGeneration == current.inProcessGeneration,
               existing.externalGeneration == current.externalGeneration {
                return LookupResult(
                    pack: existing,
                    inProcess: current.inProcessGeneration,
                    external: current.externalGeneration,
                    dataVersion: dataVersion)
            }
            return LookupResult(
                pack: nil,
                inProcess: current.inProcessGeneration,
                external: current.externalGeneration,
                dataVersion: dataVersion)
        }
    }

    func store(
        _ pack: SemanticVectorPack,
        observedDataVersion: Int64,
        on database: Database
    ) {
        let connectionID = ObjectIdentifier(database)
        state.withLock { current in
            guard pack.inProcessGeneration == current.inProcessGeneration,
                  pack.externalGeneration == current.externalGeneration
            else { return }
            current.pack = pack
            current.seenDataVersions.removeAll(keepingCapacity: true)
            current.seenDataVersions[connectionID] = observedDataVersion
            if current.scratchPool.isEmpty {
                let warmScratch = SemanticVectorScratchBuffers()
                warmScratch.ensureCapacity(
                    dimension: pack.dimension,
                    variantCount: 4,
                    tileRows: SemanticPackScorer.tileRows)
                current.scratchPool.append(warmScratch)
            }
        }
    }

    func checkoutScratch(
        dimension: Int,
        variantCount: Int,
        tileRows: Int
    ) -> SemanticVectorScratchBuffers {
        let buffers = state.withLock { current -> SemanticVectorScratchBuffers in
            current.scratchPool.popLast() ?? SemanticVectorScratchBuffers()
        }
        buffers.ensureCapacity(
            dimension: dimension,
            variantCount: variantCount,
            tileRows: tileRows)
        return buffers
    }

    func checkinScratch(_ buffers: SemanticVectorScratchBuffers) {
        state.withLock { current in
            if current.scratchPool.count < 4 {
                current.scratchPool.append(buffers)
            }
        }
    }
}

enum SemanticPackScorer {
    static let tileRows = 64
    static let maxShortlistCount = 512
    private static let float16SafeMagnitude: Float = 65_500.0
    private static let quantizationMargin: Float = 2e-3

    static func convertFloatsToHalf(
        _ source: UnsafeBufferPointer<Float>,
        into destination: UnsafeMutableBufferPointer<UInt16>
    ) {
        guard let srcBase = source.baseAddress,
              let dstBase = destination.baseAddress,
              !source.isEmpty
        else { return }
        var srcBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: srcBase),
            height: 1,
            width: vImagePixelCount(source.count),
            rowBytes: source.count * MemoryLayout<Float>.stride)
        var dstBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(dstBase),
            height: 1,
            width: vImagePixelCount(source.count),
            rowBytes: source.count * MemoryLayout<UInt16>.stride)
        _ = vImageConvert_PlanarFtoPlanar16F(&srcBuffer, &dstBuffer, 0)
    }

    static func convertHalfToFloats(
        _ source: UnsafeBufferPointer<UInt16>,
        into destination: UnsafeMutableBufferPointer<Float>
    ) {
        guard let srcBase = source.baseAddress,
              let dstBase = destination.baseAddress,
              !source.isEmpty
        else { return }
        var srcBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: srcBase),
            height: 1,
            width: vImagePixelCount(source.count),
            rowBytes: source.count * MemoryLayout<UInt16>.stride)
        var dstBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(dstBase),
            height: 1,
            width: vImagePixelCount(source.count),
            rowBytes: source.count * MemoryLayout<Float>.stride)
        _ = vImageConvert_Planar16FtoPlanarF(&srcBuffer, &dstBuffer, 0)
    }

    static func inspectVector(
        _ rawBuffer: UnsafeRawBufferPointer,
        into destination: UnsafeMutablePointer<Float>,
        dimension: Int
    ) -> (isValid: Bool, exceedsHalfRange: Bool) {
        guard let base = rawBuffer.baseAddress else { return (false, false) }
        memcpy(destination, base, dimension * MemoryLayout<Float>.size)
        var maxMagnitude: Float = 0
        vDSP_maxmgv(destination, 1, &maxMagnitude, vDSP_Length(dimension))
        guard maxMagnitude.isFinite else { return (false, false) }
        // NaN can hide from vDSP_maxmgv depending on lane position; verify finiteness via sum of squares.
        var sumSquares: Float = 0
        vDSP_svesq(destination, 1, &sumSquares, vDSP_Length(dimension))
        guard sumSquares.isFinite else { return (false, false) }
        return (true, maxMagnitude > float16SafeMagnitude)
    }

    static func shortlistIndices(
        in pack: SemanticVectorPack,
        flattenedQueries: [Float],
        variantCount: Int,
        limit: Int,
        scratch: SemanticVectorScratchBuffers
    ) -> [[Int]]? {
        guard !pack.isEmpty else {
            return [[Int]](repeating: [], count: variantCount)
        }
        prepareTransposedNormalizedQueries(
            flattenedQueries: flattenedQueries,
            dimension: pack.dimension,
            variantCount: variantCount,
            into: &scratch.transposedQueries)

        var topKScores = [[Float]](repeating: [], count: variantCount)
        var candidates = [[(index: Int, score: Float)]](repeating: [], count: variantCount)
        for slot in 0..<variantCount {
            topKScores[slot].reserveCapacity(min(limit, 64))
            candidates[slot].reserveCapacity(128)
        }

        scoreAllTiles(
            in: pack,
            variantCount: variantCount,
            limit: limit,
            scratch: scratch,
            topKScores: &topKScores,
            candidates: &candidates)

        return finalizeShortlists(
            in: pack,
            variantCount: variantCount,
            limit: limit,
            topKScores: topKScores,
            candidates: candidates)
    }

    private struct TileDimensions {
        let tileStart: Int
        let rows: Int
        let variantCount: Int
        let limit: Int
    }

    private static func scoreAllTiles(
        in pack: SemanticVectorPack,
        variantCount: Int,
        limit: Int,
        scratch: SemanticVectorScratchBuffers,
        topKScores: inout [[Float]],
        candidates: inout [[(index: Int, score: Float)]]
    ) {
        let dimension = pack.dimension
        pack.packedVectors.withUnsafeBufferPointer { packedPtr in
            scratch.tileFloats.withUnsafeMutableBufferPointer { tileFloatPtr in
                scratch.transposedQueries.withUnsafeBufferPointer { queryPtr in
                    scratch.tileScores.withUnsafeMutableBufferPointer { scorePtr in
                        guard let packedBase = packedPtr.baseAddress,
                              let floatBase = tileFloatPtr.baseAddress,
                              let queryBase = queryPtr.baseAddress,
                              let scoreBase = scorePtr.baseAddress
                        else { return }

                        for tileStart in stride(from: 0, to: pack.count, by: tileRows) {
                            let rows = min(tileRows, pack.count - tileStart)
                            let elementCount = rows * dimension
                            convertHalfToFloats(
                                UnsafeBufferPointer(start: packedBase + tileStart * dimension, count: elementCount),
                                into: UnsafeMutableBufferPointer(start: floatBase, count: elementCount))
                            vDSP_mmul(
                                floatBase, 1, queryBase, 1, scoreBase, 1,
                                vDSP_Length(rows), vDSP_Length(variantCount), vDSP_Length(dimension))
                            admitTileScores(
                                scoreBase: scoreBase,
                                tile: TileDimensions(
                                    tileStart: tileStart, rows: rows, variantCount: variantCount, limit: limit),
                                topKScores: &topKScores,
                                candidates: &candidates)
                        }
                    }
                }
            }
        }
    }

    private static func admitTileScores(
        scoreBase: UnsafePointer<Float>,
        tile: TileDimensions,
        topKScores: inout [[Float]],
        candidates: inout [[(index: Int, score: Float)]]
    ) {
        for rowOffset in 0..<tile.rows {
            let entryIndex = tile.tileStart + rowOffset
            let rowScoreBase = rowOffset * tile.variantCount
            for slot in 0..<tile.variantCount {
                let approx = scoreBase[rowScoreBase + slot]
                guard approx.isFinite else { continue }
                let currentFloor = topKScores[slot].count == tile.limit
                    ? topKScores[slot][tile.limit - 1]
                    : -.infinity
                if approx >= currentFloor - quantizationMargin {
                    candidates[slot].append((entryIndex, approx))
                    if approx > currentFloor {
                        insertDescending(approx, into: &topKScores[slot], limit: tile.limit)
                    }
                }
            }
        }
    }

    private static func finalizeShortlists(
        in pack: SemanticVectorPack,
        variantCount: Int,
        limit: Int,
        topKScores: [[Float]],
        candidates: [[(index: Int, score: Float)]]
    ) -> [[Int]]? {
        var result = [[Int]](repeating: [], count: variantCount)
        for slot in 0..<variantCount {
            let floor = (topKScores[slot].count == limit ? topKScores[slot][limit - 1] : -.infinity)
                - quantizationMargin
            let capacity = min(
                candidates[slot].count + pack.alwaysRerankIndices.count,
                maxShortlistCount + 1)
            var filtered: [Int] = []
            filtered.reserveCapacity(capacity)
            for item in candidates[slot] where item.score >= floor {
                filtered.append(item.index)
            }
            if !pack.alwaysRerankIndices.isEmpty {
                let existing = Set(filtered)
                for index in pack.alwaysRerankIndices where !existing.contains(index) {
                    filtered.append(index)
                }
                filtered.sort()
            }
            if filtered.count > maxShortlistCount {
                return nil
            }
            result[slot] = filtered
        }
        return result
    }

    private static func prepareTransposedNormalizedQueries(
        flattenedQueries: [Float],
        dimension: Int,
        variantCount: Int,
        into transposed: inout [Float]
    ) {
        var normalized = flattenedQueries
        normalized.withUnsafeMutableBufferPointer { normPtr in
            guard let base = normPtr.baseAddress else { return }
            for slot in 0..<variantCount {
                let ptr = base + slot * dimension
                var sumSq: Float = 0
                vDSP_svesq(ptr, 1, &sumSq, vDSP_Length(dimension))
                let norm = sqrt(sumSq)
                if norm > 0, norm != 1 {
                    var inv = 1.0 / norm
                    vDSP_vsmul(ptr, 1, &inv, ptr, 1, vDSP_Length(dimension))
                }
            }
            transposed.withUnsafeMutableBufferPointer { dstPtr in
                guard let dstBase = dstPtr.baseAddress else { return }
                if variantCount == 1 {
                    memcpy(dstBase, base, dimension * MemoryLayout<Float>.size)
                } else {
                    vDSP_mtrans(
                        base, 1,
                        dstBase, 1,
                        vDSP_Length(dimension),
                        vDSP_Length(variantCount))
                }
            }
        }
    }

    private static func insertDescending(
        _ score: Float,
        into topK: inout [Float],
        limit: Int
    ) {
        let idx = topK.firstIndex { score > $0 } ?? topK.endIndex
        if idx < limit {
            topK.insert(score, at: idx)
            if topK.count > limit {
                topK.removeLast()
            }
        }
    }
}
