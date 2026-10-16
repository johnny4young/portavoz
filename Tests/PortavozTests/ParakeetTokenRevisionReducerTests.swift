import Foundation
import XCTest

@testable import TranscriptionKit

final class ParakeetTokenRevisionReducerTests: XCTestCase {
    typealias Reducer = ParakeetTokenRevisionReducer

    func testProducerRetirementReplacesProvisionalWordAndDrainCommitsOnce() throws {
        for (opening, fragment, replacement) in [
            ("▁Keep", "▁an", "▁analyzing"), ("▁Estamos", "▁anal", "▁analizando"),
        ] {
            var reducer = Reducer()
            let first = try reducer.apply(
                [token(opening, at: 0), token(fragment, at: 0.2)],
                revision: revision(1, previous: 0, retained: 0, stable: 1))
            XCTAssertEqual(first.committed.map(\.piece), [opening])
            XCTAssertEqual(first.provisional.map(\.piece), [fragment])

            let replaced = try reducer.apply(
                [token(replacement, at: 0.24)],
                revision: revision(2, previous: 2, retained: 1, stable: 1))
            XCTAssertTrue(replaced.committed.isEmpty)
            XCTAssertEqual(replaced.provisional.map(\.piece), [replacement])

            let final = try reducer.apply(
                [], revision: revision(3, previous: 2, retained: 2, stable: 2, terminal: true))
            XCTAssertEqual(final.committed.map(\.piece), [replacement])
            XCTAssertTrue(final.provisional.isEmpty)
            XCTAssertTrue(reducer.isFinished)
            XCTAssertNoThrow(try reducer.finish())
            assertFailure(.alreadyFinished) {
                try reducer.apply([], revision: self.revision(4, previous: 2, retained: 2, stable: 2))
            }
        }
    }

    func testRepeatedWordsAndEqualTimeSubwordsAreNotDeduplicated() throws {
        var reducer = Reducer()
        let first = try reducer.apply(
            [token("▁very", at: 0), token("▁very", at: 0)],
            revision: revision(1, previous: 0, retained: 0, stable: 1))
        let second = try reducer.apply(
            [token("▁meet", at: 0.2), token("ing", at: 0.2), token(".", at: 0.2)],
            revision: revision(2, previous: 2, retained: 2, stable: 2))
        let final = try reducer.apply(
            [], revision: revision(3, previous: 5, retained: 5, stable: 5, terminal: true))
        XCTAssertEqual((first.committed + second.committed + final.committed).map(\.piece), [
            "▁very", "▁very", "▁meet", "ing", ".",
        ])
    }

    func testEmptyRetirementClearsPreviewAndFinalEmptySessionIsValid() throws {
        var reducer = Reducer()
        _ = try reducer.apply([token("▁temporary", at: 0)],
                              revision: revision(1, previous: 0, retained: 0, stable: 0))
        let removed = try reducer.apply([], revision: revision(2, previous: 1, retained: 0, stable: 0))
        XCTAssertEqual(removed, Reducer.Projection(committed: [], provisional: []))
        XCTAssertEqual(reducer.tokenCount, 0)
        let final = try reducer.apply(
            [], revision: revision(3, previous: 0, retained: 0, stable: 0, terminal: true))
        XCTAssertTrue(final.committed.isEmpty)
        XCTAssertTrue(reducer.isFinished)
    }

    func testInvalidRevisionCannotMutatePendingState() throws {
        var reducer = Reducer()
        _ = try reducer.apply([token("▁Keep", at: 0), token("▁tail", at: 0.2)],
                              revision: revision(1, previous: 0, retained: 0, stable: 1))
        let next = revision(2, previous: 2, retained: 2, stable: 2)
        assertFailure(.missingRevision) { try reducer.apply([], revision: nil) }
        assertFailure(.invalidOrdinal) {
            try reducer.apply([], revision: self.revision(1, previous: 2, retained: 2, stable: 2))
        }
        assertFailure(.invalidOrdinal) {
            try reducer.apply([], revision: self.revision(3, previous: 2, retained: 2, stable: 2))
        }
        assertFailure(.invalidCounts) {
            try reducer.apply([], revision: self.revision(2, previous: 3, retained: 2, stable: 2))
        }
        assertFailure(.committedPrefixRetired) {
            try reducer.apply([], revision: self.revision(2, previous: 2, retained: 0, stable: 1))
        }
        assertFailure(.invalidCounts) {
            try reducer.apply([], revision: self.revision(2, previous: 2, retained: 2, stable: 3))
        }
        assertFailure(.invalidCounts) {
            try reducer.apply([], revision: self.revision(2, previous: 2, retained: 2, stable: 1, terminal: true))
        }
        assertFailure(.invalidTokens) { try reducer.apply([self.token("▁bad", at: .nan)], revision: next) }
        XCTAssertEqual(reducer.ordinal, 1)
        XCTAssertEqual(reducer.tokenCount, 2)
        XCTAssertEqual(reducer.stableTokenCount, 1)
        let accepted = try reducer.apply([], revision: next)
        XCTAssertEqual(accepted.committed.map(\.piece), ["▁tail"])
    }

    func testInvalidRegionAndReorderedTokensCannotAdvanceOrdinal() throws {
        var reducer = Reducer()
        let invalid = Reducer.Revision(
            ordinal: 1, previousTokenCount: 0, retainedTokenCount: 0, stableTokenCount: 0,
            window: 0..<100, center: 0..<101, isTerminal: false)
        assertFailure(.invalidRegion) { try reducer.apply([], revision: invalid) }
        assertFailure(.invalidTokens) {
            try reducer.apply([self.token("▁late", at: 1), self.token("▁early", at: 0)],
                              revision: self.revision(1, previous: 0, retained: 0, stable: 0))
        }
        XCTAssertEqual(reducer.ordinal, 0)
        XCTAssertEqual(reducer.tokenCount, 0)
    }

    func testIndependentJobsDoNotShareTokensOrdinalsOrCompletion() throws {
        var first = Reducer()
        var second = Reducer()
        _ = try first.apply([token("▁first", at: 0)],
                            revision: revision(1, previous: 0, retained: 0, stable: 1, terminal: true))
        let output = try second.apply([token("▁second", at: 0)],
                                      revision: revision(1, previous: 0, retained: 0, stable: 0))
        XCTAssertEqual(output.provisional.map(\.piece), ["▁second"])
        XCTAssertFalse(second.isFinished)
    }

    func testStreamEndWithoutProducerTerminalCannotCommitPendingText() throws {
        var reducer = Reducer()
        _ = try reducer.apply([token("▁pending", at: 0)],
                              revision: revision(1, previous: 0, retained: 0, stable: 0))
        XCTAssertThrowsError(try reducer.finish()) { error in
            XCTAssertEqual(error as? Reducer.Failure, .incompleteStream)
        }
        XCTAssertEqual(reducer.stableTokenCount, 0)
        XCTAssertFalse(reducer.isFinished)
    }

    private func token(_ piece: String, at start: Double) -> Reducer.Token {
        Reducer.Token(id: 1, piece: piece, start: start, end: start + 0.08, confidence: 1)
    }

    private func revision(
        _ ordinal: Int, previous: Int, retained: Int, stable: Int, terminal: Bool = false
    ) -> Reducer.Revision {
        Reducer.Revision(
            ordinal: ordinal, previousTokenCount: previous, retainedTokenCount: retained,
            stableTokenCount: stable, window: 0..<16_000, center: 0..<16_000, isTerminal: terminal)
    }

    private func assertFailure(
        _ expected: Reducer.Failure, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> Reducer.Projection
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? Reducer.Failure, expected, file: file, line: line)
        }
    }
}
