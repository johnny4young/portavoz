import CSQLiteVecResearch
import Foundation
import PortavozCore
import StorageKit

public struct SQLiteVecShadowEntry: Equatable, Sendable {
    public let identity: SemanticSearchCandidateIdentity
    public let vector: [Float]

    public init(
        identity: SemanticSearchCandidateIdentity,
        vector: [Float]
    ) {
        self.identity = identity
        self.vector = vector
    }
}

public enum SQLiteVecExactShadowRankerError: Error, Equatable, Sendable {
    case invalidProfile
    case tooManyEntries
    case invalidIdentity(position: Int)
    case duplicateSegment(position: Int)
    case invalidVector(position: Int)
    case profileMismatch
    case invalidQuery
    case engineFailure(code: Int32)
}

/// Disposable sqlite-vec exact ranker for benchmark-only shadow composition.
///
/// The actor owns one in-memory index and emits only ordered source identity.
/// No meeting database, transcript text, or durable derived state crosses this
/// target. Shipping app and CLI targets do not depend on this module.
public actor SQLiteVecExactShadowRanker {
    private let profile: SemanticEmbeddingProfile
    private let identities: [SemanticSearchCandidateIdentity]
    private let index: SQLiteVecIndexStorage?

    public init(
        profile: SemanticEmbeddingProfile,
        entries: [SQLiteVecShadowEntry]
    ) throws {
        guard profile.isValid,
              profile.vectorDimension <= Int(Int32.max)
        else {
            throw SQLiteVecExactShadowRankerError.invalidProfile
        }
        guard entries.count <= Int(Int32.max) else {
            throw SQLiteVecExactShadowRankerError.tooManyEntries
        }

        var segmentIDs: Set<UUID> = []
        var flattened: [Float] = []
        flattened.reserveCapacity(entries.count * profile.vectorDimension)
        for (position, entry) in entries.enumerated() {
            guard entry.identity.transcriptRevision >= 0 else {
                throw SQLiteVecExactShadowRankerError.invalidIdentity(position: position)
            }
            guard segmentIDs.insert(entry.identity.segmentID).inserted else {
                throw SQLiteVecExactShadowRankerError.duplicateSegment(position: position)
            }
            guard entry.vector.count == profile.vectorDimension,
                  entry.vector.allSatisfy(\.isFinite)
            else {
                throw SQLiteVecExactShadowRankerError.invalidVector(position: position)
            }
            flattened.append(contentsOf: entry.vector)
        }

        self.profile = profile
        self.identities = entries.map(\.identity)
        self.index = entries.isEmpty
            ? nil
            : try SQLiteVecIndexStorage(
                vectors: flattened,
                count: entries.count,
                dimension: profile.vectorDimension)
    }

    public func rankedCandidates(
        for query: [Float],
        profile requestedProfile: SemanticEmbeddingProfile,
        limit: Int
    ) async throws -> [SemanticSearchCandidateIdentity] {
        guard limit > 0, let index else { return [] }
        guard requestedProfile == profile else {
            throw SQLiteVecExactShadowRankerError.profileMismatch
        }
        guard query.count == profile.vectorDimension,
              query.allSatisfy(\.isFinite)
        else {
            throw SQLiteVecExactShadowRankerError.invalidQuery
        }
        try Task.checkCancellation()

        let cancellation = try SQLiteVecCancellationStorage()
        let rankedPositions = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = index.rank(
                query: query,
                limit: min(limit, identities.count),
                cancellation: cancellation)
            switch result.status {
            case SQLiteCode.ok:
                return result.positions
            case SQLiteCode.interrupt:
                throw CancellationError()
            default:
                throw SQLiteVecExactShadowRankerError.engineFailure(
                    code: result.status)
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return rankedPositions.map { identities[$0] }
    }
}

private enum SQLiteCode {
    static let ok: Int32 = 0
    static let noMemory: Int32 = 7
    static let interrupt: Int32 = 9
}

private final class SQLiteVecCancellationStorage: @unchecked Sendable {
    let pointer: OpaquePointer

    init() throws {
        guard let pointer = portavoz_sqlite_vec_cancellation_create() else {
            throw SQLiteVecExactShadowRankerError.engineFailure(
                code: SQLiteCode.noMemory)
        }
        self.pointer = pointer
    }

    deinit {
        portavoz_sqlite_vec_cancellation_destroy(pointer)
    }

    func cancel() {
        portavoz_sqlite_vec_cancellation_cancel(pointer)
    }
}

private final class SQLiteVecIndexStorage: @unchecked Sendable {
    private let pointer: OpaquePointer
    private let dimension: Int

    init(
        vectors: [Float],
        count: Int,
        dimension: Int
    ) throws {
        var created: OpaquePointer?
        let status = vectors.withUnsafeBufferPointer { buffer in
            portavoz_sqlite_vec_index_create(
                buffer.baseAddress,
                Int32(count),
                Int32(dimension),
                &created)
        }
        guard status == SQLiteCode.ok, let created else {
            throw SQLiteVecExactShadowRankerError.engineFailure(code: status)
        }
        self.pointer = created
        self.dimension = dimension
    }

    deinit {
        portavoz_sqlite_vec_index_destroy(pointer)
    }

    func rank(
        query: [Float],
        limit: Int,
        cancellation: SQLiteVecCancellationStorage
    ) -> (status: Int32, positions: [Int]) {
        var output = [Int32](repeating: -1, count: limit)
        var outputCount: Int32 = 0
        let status = query.withUnsafeBufferPointer { queryBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                portavoz_sqlite_vec_index_rank(
                    pointer,
                    queryBuffer.baseAddress,
                    Int32(dimension),
                    Int32(limit),
                    outputBuffer.baseAddress,
                    Int32(outputBuffer.count),
                    &outputCount,
                    cancellation.pointer)
            }
        }
        guard status == SQLiteCode.ok else { return (status, []) }
        return (status, output.prefix(Int(outputCount)).map(Int.init))
    }
}
