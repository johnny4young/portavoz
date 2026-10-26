import Foundation

/// Reduces producer-owned token edits without inferring identity from text or
/// timestamps. Each serving native job owns one reducer and a mutable suffix.
struct ParakeetTokenRevisionReducer: Sendable {
    struct Token: Equatable, Sendable {
        let id: Int
        let piece: String
        let start: TimeInterval
        let end: TimeInterval
        let confidence: Float
    }

    /// Counts refer to canonical token positions in one producer job. Tokens
    /// before `stableTokenCount` are irrevocable, even if display confidence is low.
    struct Revision: Sendable {
        let ordinal: Int
        let previousTokenCount: Int
        let retainedTokenCount: Int
        let stableTokenCount: Int
        let window: Range<Int>
        let center: Range<Int>
        let isTerminal: Bool
    }

    struct Projection: Equatable, Sendable {
        let committed: [Token]
        let provisional: [Token]
    }

    enum Failure: Error, Equatable {
        case missingRevision, invalidOrdinal, invalidCounts, invalidRegion
        case invalidTokens, committedPrefixRetired, alreadyFinished, incompleteStream
    }

    private(set) var ordinal = 0
    private(set) var tokenCount = 0
    private(set) var stableTokenCount = 0
    private(set) var isFinished = false
    private var pending: [Token] = []
    private var previousCenterStart = 0
    private var previousWindowEnd = 0

    /// EOF alone cannot promote a provisional tail. Only the producer's
    /// terminal revision can establish that no further retirement is possible.
    func finish() throws {
        guard isFinished else { throw Failure.incompleteStream }
    }

    /// Validation and mutation are atomic. An empty update can retire or finalize
    /// a pending suffix; it must not be discarded merely because it has no text.
    mutating func apply(_ tokens: [Token], revision: Revision?) throws -> Projection {
        guard !isFinished else { throw Failure.alreadyFinished }
        guard let revision else { throw Failure.missingRevision }
        let nextOrdinal = ordinal.addingReportingOverflow(1)
        guard !nextOrdinal.overflow, revision.ordinal == nextOrdinal.partialValue else {
            throw Failure.invalidOrdinal
        }
        try validateCounts(revision, appended: tokens.count)
        try validateRegion(revision)
        guard tokens.allSatisfy({
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
                && $0.confidence.isFinite && (0...1).contains($0.confidence)
        }), zip(tokens, tokens.dropFirst()).allSatisfy({ $0.start <= $1.start }) else {
            throw Failure.invalidTokens
        }

        let retainedPending = revision.retainedTokenCount - stableTokenCount
        let nextPending = Array(pending.prefix(retainedPending)) + tokens
        let newlyStable = revision.stableTokenCount - stableTokenCount
        let projection = Projection(
            committed: Array(nextPending.prefix(newlyStable)),
            provisional: Array(nextPending.dropFirst(newlyStable)))

        pending = projection.provisional
        ordinal = revision.ordinal
        tokenCount = revision.retainedTokenCount + tokens.count
        stableTokenCount = revision.stableTokenCount
        previousCenterStart = revision.center.lowerBound
        previousWindowEnd = revision.window.upperBound
        isFinished = revision.isTerminal
        return projection
    }

    private func validateCounts(_ revision: Revision, appended: Int) throws {
        guard revision.previousTokenCount == tokenCount,
              revision.retainedTokenCount >= 0,
              revision.retainedTokenCount <= tokenCount,
              revision.stableTokenCount >= 0 else { throw Failure.invalidCounts }
        guard revision.retainedTokenCount >= stableTokenCount,
              revision.stableTokenCount >= stableTokenCount else {
            throw Failure.committedPrefixRetired
        }
        let total = revision.retainedTokenCount.addingReportingOverflow(appended)
        guard !total.overflow, revision.stableTokenCount <= total.partialValue,
              !revision.isTerminal || revision.stableTokenCount == total.partialValue else {
            throw Failure.invalidCounts
        }
    }

    private func validateRegion(_ revision: Revision) throws {
        guard revision.window.lowerBound >= 0,
              revision.window.lowerBound <= revision.center.lowerBound,
              revision.center.upperBound <= revision.window.upperBound,
              revision.center.lowerBound >= previousCenterStart,
              revision.window.upperBound >= previousWindowEnd else {
            throw Failure.invalidRegion
        }
    }
}
