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
