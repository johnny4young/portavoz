import Foundation

/// Coarse language buckets for content-free field-quality aggregation.
/// Observations never carry transcript text, names, or meeting titles.
public enum CommitmentFieldQualityLanguage: String, Codable, CaseIterable, Sendable {
    case english
    case spanish
    case mixed
}

/// The latest human disposition for one generated commitment source.
/// Pending and deferred observations are intentionally not terminal reviews.
public enum CommitmentFieldQualityOutcome: String, Codable, CaseIterable, Sendable {
    case pending
    case deferred
    case dismissed
    case confirmed
}

/// The authority that supported an explicit confirmation.
/// `missing` remains representable so a field gate can fail instead of hiding
/// an invalid confirmation from its evidence-coverage denominator.
public enum CommitmentFieldConfirmationBasis: String, Codable, CaseIterable, Sendable {
    case generatedDirectEvidence = "generated-direct-evidence"
    case userNote = "user-note"
    case manual
    case missing

    public var satisfiesEvidenceRequirement: Bool { self != .missing }
}

/// One content-free observation for a rolling Commitment Radar quality report.
/// Owner tokens are opaque fixture- or installation-local UUIDs. They cannot
/// carry names, email addresses, or other user-visible content.
public struct CommitmentFieldQualityObservation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let language: CommitmentFieldQualityLanguage
    public let firstPresentedAt: Date
    public let outcome: CommitmentFieldQualityOutcome
    public let reviewedAt: Date?
    public let suggestedOwnerToken: UUID?
    public let confirmedOwnerToken: UUID?
    public let suggestedDueAt: Date?
    public let confirmedDueAt: Date?
    public let confirmationBasis: CommitmentFieldConfirmationBasis?

    public init(
        id: UUID = UUID(),
        language: CommitmentFieldQualityLanguage,
        firstPresentedAt: Date,
        outcome: CommitmentFieldQualityOutcome,
        reviewedAt: Date? = nil,
        suggestedOwnerToken: UUID? = nil,
        confirmedOwnerToken: UUID? = nil,
        suggestedDueAt: Date? = nil,
        confirmedDueAt: Date? = nil,
        confirmationBasis: CommitmentFieldConfirmationBasis? = nil
    ) {
        self.id = id
        self.language = language
        self.firstPresentedAt = firstPresentedAt
        self.outcome = outcome
        self.reviewedAt = reviewedAt
        self.suggestedOwnerToken = suggestedOwnerToken
        self.confirmedOwnerToken = confirmedOwnerToken
        self.suggestedDueAt = suggestedDueAt
        self.confirmedDueAt = confirmedDueAt
        self.confirmationBasis = confirmationBasis
    }
}

public struct CommitmentFieldQualityMetrics: Codable, Equatable, Sendable {
    public let observationCount: Int
    public let pendingCount: Int
    public let deferredCount: Int
    public let dismissedCount: Int
    public let confirmedCount: Int
    public let terminalReviewCount: Int
    public let reviewFalsePositiveRate: Double?
    public let ownerClaimCount: Int
    public let exactOwnerClaimCount: Int
    public let ownerPrecision: Double?
    public let dueDateClaimCount: Int
    public let exactDueDateClaimCount: Int
    public let dueDatePrecision: Double?
    public let evidenceCoveredConfirmationCount: Int
    public let evidenceCoverage: Double?
    public let confirmationLatencyCount: Int
    public let confirmationLatencyP50: TimeInterval?
    public let confirmationLatencyP95: TimeInterval?
}

public struct CommitmentFieldQualityBreakdown: Codable, Equatable, Sendable {
    public let language: CommitmentFieldQualityLanguage
    public let metrics: CommitmentFieldQualityMetrics
}

public struct CommitmentFieldQualityScorecard: Codable, Equatable, Sendable {
    public let windowStartedAt: Date
    public let windowEndedAt: Date
    public let overall: CommitmentFieldQualityMetrics
    public let byLanguage: [CommitmentFieldQualityBreakdown]
}

public enum CommitmentFieldQualityError: Error, Equatable, Sendable {
    case invalidWindowEnd
    case tooManyObservations
    case duplicateObservation(UUID)
    case observationOutsideWindow(UUID)
    case invalidObservation(UUID)
}

/// Pure rolling-cohort evaluator. It makes no product decision and treats a
/// dismissal as a field false-positive proxy, not as labeled model ground truth.
public enum CommitmentFieldQualityEvaluator {
    public static let windowDayCount = 90
    public static let maximumObservationCount = 50_000
    public static let windowDuration = TimeInterval(windowDayCount * 24 * 60 * 60)

    public static func evaluate(
        _ observations: [CommitmentFieldQualityObservation],
        endingAt windowEndedAt: Date
    ) throws -> CommitmentFieldQualityScorecard {
        guard windowEndedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CommitmentFieldQualityError.invalidWindowEnd
        }
        guard observations.count <= maximumObservationCount else {
            throw CommitmentFieldQualityError.tooManyObservations
        }

        let windowStartedAt = windowEndedAt.addingTimeInterval(-windowDuration)
        var seen: Set<UUID> = []
        for observation in observations {
            guard seen.insert(observation.id).inserted else {
                throw CommitmentFieldQualityError.duplicateObservation(observation.id)
            }
            guard observation.firstPresentedAt >= windowStartedAt,
                  observation.firstPresentedAt <= windowEndedAt,
                  observation.reviewedAt.map({ $0 <= windowEndedAt }) ?? true
            else {
                throw CommitmentFieldQualityError.observationOutsideWindow(observation.id)
            }
            guard isValid(observation) else {
                throw CommitmentFieldQualityError.invalidObservation(observation.id)
            }
        }

        let breakdowns = CommitmentFieldQualityLanguage.allCases.map { language in
            CommitmentFieldQualityBreakdown(
                language: language,
                metrics: metrics(for: observations.filter { $0.language == language }))
        }
        return CommitmentFieldQualityScorecard(
            windowStartedAt: windowStartedAt,
            windowEndedAt: windowEndedAt,
            overall: metrics(for: observations),
            byLanguage: breakdowns)
    }
}

private extension CommitmentFieldQualityEvaluator {
    static func isValid(_ observation: CommitmentFieldQualityObservation) -> Bool {
        guard observation.firstPresentedAt.timeIntervalSinceReferenceDate.isFinite,
              finite(observation.reviewedAt),
              finite(observation.suggestedDueAt),
              finite(observation.confirmedDueAt)
        else { return false }

        switch observation.outcome {
        case .pending, .deferred:
            return observation.reviewedAt == nil
                && observation.confirmedOwnerToken == nil
                && observation.confirmedDueAt == nil
                && observation.confirmationBasis == nil
        case .dismissed:
            return validTerminalDate(observation)
                && observation.confirmedOwnerToken == nil
                && observation.confirmedDueAt == nil
                && observation.confirmationBasis == nil
        case .confirmed:
            return validTerminalDate(observation)
                && observation.confirmationBasis != nil
        }
    }

    static func validTerminalDate(_ observation: CommitmentFieldQualityObservation) -> Bool {
        guard let reviewedAt = observation.reviewedAt else { return false }
        return reviewedAt >= observation.firstPresentedAt
    }

    static func finite(_ date: Date?) -> Bool {
        date?.timeIntervalSinceReferenceDate.isFinite ?? true
    }

    static func metrics(
        for observations: [CommitmentFieldQualityObservation]
    ) -> CommitmentFieldQualityMetrics {
        let pendingCount = observations.count { $0.outcome == .pending }
        let deferredCount = observations.count { $0.outcome == .deferred }
        let dismissed = observations.filter { $0.outcome == .dismissed }
        let confirmed = observations.filter { $0.outcome == .confirmed }
        let terminal = dismissed + confirmed
        let ownerClaims = terminal.filter { $0.suggestedOwnerToken != nil }
        let dueDateClaims = terminal.filter { $0.suggestedDueAt != nil }
        let exactOwnerClaims = ownerClaims.count { observation in
            observation.outcome == .confirmed
                && observation.suggestedOwnerToken == observation.confirmedOwnerToken
        }
        let exactDueDateClaims = dueDateClaims.count { observation in
            observation.outcome == .confirmed
                && sameInstant(observation.suggestedDueAt, observation.confirmedDueAt)
        }
        let coveredConfirmations = confirmed.count {
            $0.confirmationBasis?.satisfiesEvidenceRequirement == true
        }
        let latencies = confirmed.compactMap { observation -> TimeInterval? in
            guard let reviewedAt = observation.reviewedAt else { return nil }
            return reviewedAt.timeIntervalSince(observation.firstPresentedAt)
        }.sorted()

        return CommitmentFieldQualityMetrics(
            observationCount: observations.count,
            pendingCount: pendingCount,
            deferredCount: deferredCount,
            dismissedCount: dismissed.count,
            confirmedCount: confirmed.count,
            terminalReviewCount: terminal.count,
            reviewFalsePositiveRate: ratio(dismissed.count, terminal.count),
            ownerClaimCount: ownerClaims.count,
            exactOwnerClaimCount: exactOwnerClaims,
            ownerPrecision: ratio(exactOwnerClaims, ownerClaims.count),
            dueDateClaimCount: dueDateClaims.count,
            exactDueDateClaimCount: exactDueDateClaims,
            dueDatePrecision: ratio(exactDueDateClaims, dueDateClaims.count),
            evidenceCoveredConfirmationCount: coveredConfirmations,
            evidenceCoverage: ratio(coveredConfirmations, confirmed.count),
            confirmationLatencyCount: latencies.count,
            confirmationLatencyP50: percentile(0.50, values: latencies),
            confirmationLatencyP95: percentile(0.95, values: latencies))
    }

    static func ratio(_ numerator: Int, _ denominator: Int) -> Double? {
        guard denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    static func percentile(_ percentile: Double, values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let rank = max(1, Int(ceil(percentile * Double(values.count))))
        return values[rank - 1]
    }

    static func sameInstant(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return Int64((lhs.timeIntervalSince1970 * 1_000).rounded())
            == Int64((rhs.timeIntervalSince1970 * 1_000).rounded())
    }
}
