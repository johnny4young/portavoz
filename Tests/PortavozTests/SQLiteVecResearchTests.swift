import ApplicationKit
import CSQLiteVecResearch
import Foundation
import SQLiteVecResearchKit
import StorageKit
import XCTest

final class SQLiteVecResearchTests: XCTestCase {
    func testPinnedStaticEngineRunsOneIsolatedExactQuery() {
        XCTAssertEqual(portavoz_sqlite_vec_run_exact_query_smoke(), 0)
    }

    func testExactRankerReturnsCosineOrderAndStableInsertionTies() async throws {
        let profile = semanticTestProfile()
        let identities = (0..<4).map { _ in
            SemanticSearchCandidateIdentity(
                segmentID: UUID(),
                transcriptRevision: 2)
        }
        let ranker = try SQLiteVecExactShadowRanker(
            profile: profile,
            entries: [
                SQLiteVecShadowEntry(identity: identities[0], vector: [1, 0]),
                SQLiteVecShadowEntry(identity: identities[1], vector: [0.8, 0.6]),
                SQLiteVecShadowEntry(identity: identities[2], vector: [0, 1]),
                SQLiteVecShadowEntry(identity: identities[3], vector: [0, 1]),
            ])

        let ranked = try await ranker.rankedCandidates(
            for: [1, 0],
            profile: profile,
            limit: 4)

        XCTAssertEqual(ranked, identities)
    }

    func testRankerRejectsInvalidCorpusAndQueryEvidence() async throws {
        let profile = semanticTestProfile()
        let identity = SemanticSearchCandidateIdentity(
            segmentID: UUID(),
            transcriptRevision: 1)

        XCTAssertThrowsError(try SQLiteVecExactShadowRanker(
            profile: profile,
            entries: [SQLiteVecShadowEntry(identity: identity, vector: [1])])) {
                XCTAssertEqual(
                    $0 as? SQLiteVecExactShadowRankerError,
                    .invalidVector(position: 0))
            }
        XCTAssertThrowsError(try SQLiteVecExactShadowRanker(
            profile: profile,
            entries: [
                SQLiteVecShadowEntry(identity: identity, vector: [1, 0]),
                SQLiteVecShadowEntry(identity: identity, vector: [0, 1]),
            ])) {
                XCTAssertEqual(
                    $0 as? SQLiteVecExactShadowRankerError,
                    .duplicateSegment(position: 1))
            }

        let ranker = try SQLiteVecExactShadowRanker(
            profile: profile,
            entries: [SQLiteVecShadowEntry(identity: identity, vector: [1, 0])])
        do {
            _ = try await ranker.rankedCandidates(
                for: [.nan, 0],
                profile: profile,
                limit: 1)
            XCTFail("non-finite query evidence must fail closed")
        } catch let error as SQLiteVecExactShadowRankerError {
            XCTAssertEqual(error, .invalidQuery)
        }
        do {
            _ = try await ranker.rankedCandidates(
                for: [1, 0],
                profile: semanticTestProfile(modelRevision: 2),
                limit: 1)
            XCTFail("a foreign embedding profile must fail closed")
        } catch let error as SQLiteVecExactShadowRankerError {
            XCTAssertEqual(error, .profileMismatch)
        }
    }

    func testMutationKeepsStableSlotsAcrossAddUpdateAndDelete() async throws {
        let profile = semanticTestProfile()
        let first = SemanticSearchCandidateIdentity(
            segmentID: UUID(), transcriptRevision: 0)
        let second = SemanticSearchCandidateIdentity(
            segmentID: UUID(), transcriptRevision: 0)
        let third = SemanticSearchCandidateIdentity(
            segmentID: UUID(), transcriptRevision: 0)
        let fourth = SemanticSearchCandidateIdentity(
            segmentID: UUID(), transcriptRevision: 0)
        let ranker = try SQLiteVecExactShadowRanker(
            profile: profile,
            entries: [
                .init(identity: first, vector: [1, 0]),
                .init(identity: second, vector: [0, 1]),
            ])

        try await ranker.apply(
            .init(
                upserts: [
                    .init(
                        identity: .init(
                            segmentID: second.segmentID,
                            transcriptRevision: 1),
                        vector: [1, 0]),
                    .init(identity: third, vector: [1, 0]),
                ],
                deletedSegmentIDs: []),
            profile: profile)

        let countAfterUpserts = await ranker.count
        let rankedAfterUpserts = try await ranker.rankedCandidates(
            for: [1, 0], profile: profile, limit: 3)
        XCTAssertEqual(countAfterUpserts, 3)
        XCTAssertEqual(
            rankedAfterUpserts,
            [
                first,
                .init(segmentID: second.segmentID, transcriptRevision: 1),
                third,
            ])

        try await ranker.apply(
            .init(upserts: [], deletedSegmentIDs: [second.segmentID]),
            profile: profile)

        let countAfterDeletion = await ranker.count
        let rankedAfterDeletion = try await ranker.rankedCandidates(
            for: [1, 0], profile: profile, limit: 3)
        XCTAssertEqual(countAfterDeletion, 2)
        XCTAssertEqual(
            rankedAfterDeletion,
            [first, third])

        try await ranker.apply(
            .init(
                upserts: [.init(identity: fourth, vector: [1, 0])],
                deletedSegmentIDs: []),
            profile: profile)

        let rankedAfterReplacement = try await ranker.rankedCandidates(
            for: [1, 0], profile: profile, limit: 3)
        XCTAssertEqual(rankedAfterReplacement, [first, third, fourth])
    }

    func testEmptyRankerAcceptsAnAppendedMutation() async throws {
        let profile = semanticTestProfile()
        let identity = SemanticSearchCandidateIdentity(
            segmentID: UUID(), transcriptRevision: 3)
        let ranker = try SQLiteVecExactShadowRanker(
            profile: profile,
            entries: [])

        try await ranker.apply(
            .init(
                upserts: [.init(identity: identity, vector: [0, 1])],
                deletedSegmentIDs: []),
            profile: profile)

        let count = await ranker.count
        let ranked = try await ranker.rankedCandidates(
            for: [0, 1], profile: profile, limit: 1)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(ranked, [identity])
    }

    func testInvalidMutationFailsBeforeChangingRankedEvidence() async throws {
        let profile = semanticTestProfile()
        let identity = SemanticSearchCandidateIdentity(
            segmentID: UUID(), transcriptRevision: 0)
        let ranker = try SQLiteVecExactShadowRanker(
            profile: profile,
            entries: [.init(identity: identity, vector: [1, 0])])

        do {
            try await ranker.apply(
                .init(
                    upserts: [.init(identity: identity, vector: [0, 1])],
                    deletedSegmentIDs: [identity.segmentID]),
                profile: profile)
            XCTFail("an overlapping mutation must fail closed")
        } catch let error as SQLiteVecExactShadowRankerError {
            XCTAssertEqual(error, .overlappingSegment(position: 0))
        }
        do {
            try await ranker.apply(
                .init(upserts: [], deletedSegmentIDs: [UUID()]),
                profile: profile)
            XCTFail("a deletion without current evidence must fail closed")
        } catch let error as SQLiteVecExactShadowRankerError {
            XCTAssertEqual(error, .missingDeletedSegment(position: 0))
        }
        do {
            try await ranker.apply(
                .empty,
                profile: semanticTestProfile(modelRevision: 9))
            XCTFail("a foreign mutation profile must fail closed")
        } catch let error as SQLiteVecExactShadowRankerError {
            XCTAssertEqual(error, .profileMismatch)
        }
        do {
            try await ranker.apply(
                .init(
                    upserts: [],
                    deletedSegmentIDs: [identity.segmentID, identity.segmentID]),
                profile: profile)
            XCTFail("duplicate deletion evidence must fail closed")
        } catch let error as SQLiteVecExactShadowRankerError {
            XCTAssertEqual(error, .duplicateDeletion(position: 1))
        }
        do {
            try await ranker.apply(
                .init(
                    upserts: [
                        .init(identity: identity, vector: [0, 1]),
                        .init(identity: identity, vector: [1, 0]),
                    ],
                    deletedSegmentIDs: []),
                profile: profile)
            XCTFail("duplicate upsert evidence must fail closed")
        } catch let error as SQLiteVecExactShadowRankerError {
            XCTAssertEqual(error, .duplicateSegment(position: 1))
        }
        do {
            try await ranker.apply(
                .init(
                    upserts: [.init(identity: identity, vector: [.nan, 0])],
                    deletedSegmentIDs: []),
                profile: profile)
            XCTFail("non-finite upsert evidence must fail closed")
        } catch let error as SQLiteVecExactShadowRankerError {
            XCTAssertEqual(error, .invalidVector(position: 0))
        }

        let count = await ranker.count
        let ranked = try await ranker.rankedCandidates(
            for: [1, 0], profile: profile, limit: 1)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(ranked, [identity])
    }

    func testNativeMutationRejectsNoncontiguousAppendWithoutPartialChange() throws {
        let vectors: [Float] = [1, 0]
        var index: OpaquePointer?
        XCTAssertEqual(vectors.withUnsafeBufferPointer { buffer in
            portavoz_sqlite_vec_index_create(buffer.baseAddress, 1, 2, &index)
        }, 0)
        let created = try XCTUnwrap(index)
        defer { portavoz_sqlite_vec_index_destroy(created) }

        let positions: [Int32] = [2]
        let appended: [Float] = [0, 1]
        let mutationResult = positions.withUnsafeBufferPointer { positionBuffer in
            appended.withUnsafeBufferPointer { vectorBuffer in
                portavoz_sqlite_vec_index_apply(
                    created,
                    positionBuffer.baseAddress,
                    vectorBuffer.baseAddress,
                    1,
                    nil,
                    0,
                    2)
            }
        }
        XCTAssertEqual(mutationResult, 21)

        let query: [Float] = [1, 0]
        var output: Int32 = -1
        var outputCount: Int32 = 0
        XCTAssertEqual(query.withUnsafeBufferPointer { queryBuffer in
            portavoz_sqlite_vec_index_rank(
                created,
                queryBuffer.baseAddress,
                2,
                1,
                &output,
                1,
                &outputCount,
                nil)
        }, 0)
        XCTAssertEqual(outputCount, 1)
        XCTAssertEqual(output, 0)
    }

    func testCancelledTaskDoesNotEnterTheResearchRanker() async throws {
        let profile = semanticTestProfile()
        let ranker = try SQLiteVecExactShadowRanker(
            profile: profile,
            entries: [SQLiteVecShadowEntry(
                identity: SemanticSearchCandidateIdentity(
                    segmentID: UUID(),
                    transcriptRevision: 0),
                vector: [1, 0])])

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ranker.rankedCandidates(
                for: [1, 0],
                profile: profile,
                limit: 1)
        }

        do {
            _ = try await task.value
            XCTFail("cancelled shadow work must not rank")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testPreCancelledNativeQueryReturnsSQLiteInterrupt() throws {
        let vectors: [Float] = [1, 0, 0, 1]
        var index: OpaquePointer?
        let createResult = vectors.withUnsafeBufferPointer { buffer in
            portavoz_sqlite_vec_index_create(buffer.baseAddress, 2, 2, &index)
        }
        XCTAssertEqual(createResult, 0)
        let created = try XCTUnwrap(index)
        defer { portavoz_sqlite_vec_index_destroy(created) }
        let cancellation = try XCTUnwrap(
            portavoz_sqlite_vec_cancellation_create())
        defer { portavoz_sqlite_vec_cancellation_destroy(cancellation) }
        portavoz_sqlite_vec_cancellation_cancel(cancellation)

        let query: [Float] = [1, 0]
        var output: Int32 = -1
        var outputCount: Int32 = -1
        let rankResult = query.withUnsafeBufferPointer { queryBuffer in
            portavoz_sqlite_vec_index_rank(
                created,
                queryBuffer.baseAddress,
                2,
                1,
                &output,
                1,
                &outputCount,
                cancellation)
        }

        XCTAssertEqual(rankResult, 9)
        XCTAssertEqual(outputCount, 0)
        XCTAssertEqual(output, -1)
    }
}
