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

public struct SQLiteVecShadowMutation: Equatable, Sendable {
    public let upserts: [SQLiteVecShadowEntry]
    public let deletedSegmentIDs: [UUID]

    public init(
        upserts: [SQLiteVecShadowEntry],
        deletedSegmentIDs: [UUID]
    ) {
        self.upserts = upserts
        self.deletedSegmentIDs = deletedSegmentIDs
    }

    public static let empty = SQLiteVecShadowMutation(
        upserts: [],
        deletedSegmentIDs: [])
}

public enum SQLiteVecExactShadowRankerError: Error, Equatable, Sendable {
    case invalidProfile
    case tooManyEntries
    case invalidIdentity(position: Int)
    case duplicateSegment(position: Int)
    case duplicateDeletion(position: Int)
    case missingDeletedSegment(position: Int)
    case overlappingSegment(position: Int)
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
    private struct PreparedMutation {
        let upsertPositions: [Int32]
        let vectors: [Float]
        let deletionPositions: [Int32]
    }

    private let profile: SemanticEmbeddingProfile
    private var identitySlots: [SemanticSearchCandidateIdentity?]
    private var positionsBySegmentID: [UUID: Int]
    private let index: SQLiteVecIndexStorage

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
        self.identitySlots = entries.map { Optional($0.identity) }
        self.positionsBySegmentID = Dictionary(
            uniqueKeysWithValues: entries.enumerated().map {
                ($0.element.identity.segmentID, $0.offset)
            })
        self.index = try SQLiteVecIndexStorage(
            vectors: flattened,
            count: entries.count,
            dimension: profile.vectorDimension)
    }

    public var count: Int {
        positionsBySegmentID.count
    }

    /// Applies one research-only mutation atomically. Existing identities keep
    /// their deterministic tie slot, deleted slots are never reused, and new
    /// identities append. Swift state changes only after the native transaction
    /// commits successfully.
    public func apply(
        _ mutation: SQLiteVecShadowMutation,
        profile requestedProfile: SemanticEmbeddingProfile
    ) throws {
        guard requestedProfile == profile else {
            throw SQLiteVecExactShadowRankerError.profileMismatch
        }
        guard mutation.upserts.count <= Int(Int32.max),
              mutation.deletedSegmentIDs.count <= Int(Int32.max)
        else {
            throw SQLiteVecExactShadowRankerError.tooManyEntries
        }

        let prepared = try prepare(mutation)
        let status = index.apply(
            upsertPositions: prepared.upsertPositions,
            vectors: prepared.vectors,
            deletePositions: prepared.deletionPositions)
        guard status == SQLiteCode.ok else {
            throw SQLiteVecExactShadowRankerError.engineFailure(code: status)
        }
        publish(mutation, at: prepared.upsertPositions)
    }

    private func prepare(
        _ mutation: SQLiteVecShadowMutation
    ) throws -> PreparedMutation {
        let deletions = try prepareDeletions(mutation.deletedSegmentIDs)
        let upserts = try prepareUpserts(
            mutation.upserts,
            excluding: deletions.segmentIDs)
        return PreparedMutation(
            upsertPositions: upserts.positions,
            vectors: upserts.vectors,
            deletionPositions: deletions.positions)
    }

    private func prepareDeletions(
        _ segmentIDs: [UUID]
    ) throws -> (segmentIDs: Set<UUID>, positions: [Int32]) {
        var deletionIDs: Set<UUID> = []
        var deletionPositions: [Int32] = []
        deletionPositions.reserveCapacity(segmentIDs.count)
        for (position, segmentID) in segmentIDs.enumerated() {
            guard deletionIDs.insert(segmentID).inserted else {
                throw SQLiteVecExactShadowRankerError.duplicateDeletion(
                    position: position)
            }
            guard let slot = positionsBySegmentID[segmentID] else {
                throw SQLiteVecExactShadowRankerError.missingDeletedSegment(
                    position: position)
            }
            deletionPositions.append(Int32(slot))
        }
        return (deletionIDs, deletionPositions)
    }

    private func prepareUpserts(
        _ entries: [SQLiteVecShadowEntry],
        excluding deletionIDs: Set<UUID>
    ) throws -> (positions: [Int32], vectors: [Float]) {
        var upsertIDs: Set<UUID> = []
        var upsertPositions: [Int32] = []
        var flattened: [Float] = []
        upsertPositions.reserveCapacity(entries.count)
        flattened.reserveCapacity(entries.count * profile.vectorDimension)
        var nextSlot = identitySlots.count
        for (position, entry) in entries.enumerated() {
            try validate(entry, position: position)
            guard upsertIDs.insert(entry.identity.segmentID).inserted else {
                throw SQLiteVecExactShadowRankerError.duplicateSegment(
                    position: position)
            }
            guard !deletionIDs.contains(entry.identity.segmentID) else {
                throw SQLiteVecExactShadowRankerError.overlappingSegment(
                    position: position)
            }
            let slot = try resolvedSlot(
                for: entry.identity.segmentID,
                nextSlot: &nextSlot)
            upsertPositions.append(Int32(slot))
            flattened.append(contentsOf: entry.vector)
        }
        return (upsertPositions, flattened)
    }

    private func validate(
        _ entry: SQLiteVecShadowEntry,
        position: Int
    ) throws {
        guard entry.identity.transcriptRevision >= 0 else {
            throw SQLiteVecExactShadowRankerError.invalidIdentity(
                position: position)
        }
        guard entry.vector.count == profile.vectorDimension,
              entry.vector.allSatisfy(\.isFinite)
        else {
            throw SQLiteVecExactShadowRankerError.invalidVector(
                position: position)
        }
    }

    private func resolvedSlot(
        for segmentID: UUID,
        nextSlot: inout Int
    ) throws -> Int {
        if let existing = positionsBySegmentID[segmentID] {
            return existing
        }
        guard nextSlot < Int(Int32.max) else {
            throw SQLiteVecExactShadowRankerError.tooManyEntries
        }
        defer { nextSlot += 1 }
        return nextSlot
    }

    private func publish(
        _ mutation: SQLiteVecShadowMutation,
        at upsertPositions: [Int32]
    ) {
        for segmentID in mutation.deletedSegmentIDs {
            if let slot = positionsBySegmentID.removeValue(forKey: segmentID) {
                identitySlots[slot] = nil
            }
        }
        for (offset, entry) in mutation.upserts.enumerated() {
            let slot = Int(upsertPositions[offset])
            if slot == identitySlots.count {
                identitySlots.append(entry.identity)
            } else {
                identitySlots[slot] = entry.identity
            }
            positionsBySegmentID[entry.identity.segmentID] = slot
        }
    }

    public func rankedCandidates(
        for query: [Float],
        profile requestedProfile: SemanticEmbeddingProfile,
        limit: Int
    ) async throws -> [SemanticSearchCandidateIdentity] {
        guard limit > 0, !positionsBySegmentID.isEmpty else { return [] }
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
                limit: min(limit, positionsBySegmentID.count),
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
        return try rankedPositions.map { position in
            guard identitySlots.indices.contains(position),
                  let identity = identitySlots[position]
            else {
                throw SQLiteVecExactShadowRankerError.engineFailure(
                    code: SQLiteCode.corrupt)
            }
            return identity
        }
    }
}

private enum SQLiteCode {
    static let ok: Int32 = 0
    static let noMemory: Int32 = 7
    static let interrupt: Int32 = 9
    static let corrupt: Int32 = 11
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

    func apply(
        upsertPositions: [Int32],
        vectors: [Float],
        deletePositions: [Int32]
    ) -> Int32 {
        upsertPositions.withUnsafeBufferPointer { upsertBuffer in
            vectors.withUnsafeBufferPointer { vectorBuffer in
                deletePositions.withUnsafeBufferPointer { deleteBuffer in
                    portavoz_sqlite_vec_index_apply(
                        pointer,
                        upsertBuffer.baseAddress,
                        vectorBuffer.baseAddress,
                        Int32(upsertBuffer.count),
                        deleteBuffer.baseAddress,
                        Int32(deleteBuffer.count),
                        Int32(dimension))
                }
            }
        }
    }
}
