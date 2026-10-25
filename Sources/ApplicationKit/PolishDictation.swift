import Foundation
import IntelligenceKit
import TranscriptionKit

/// Why a dictation kept its clean text instead of the polished one.
public enum DictationPolishSkip: Equatable, Sendable {
    case tooShort
    case tooLong
    case unavailable(String)
    case timedOut
    case failed
    case changedMeaning(DictationPolishFidelity.Violation)
}

public enum DictationPolishOutcome: Equatable, Sendable {
    case polished(String)
    case kept(DictationPolishSkip)
}

/// Polishes one clean dictation within a deadline. Every failure keeps the clean text:
/// the caller pastes either the validated rewrite or exactly what clean produced.
public struct PolishDictation: Sendable {
    public static let timeout: Duration = .seconds(5)
    public static let minimumWords = 3
    public static let maximumCharacters = 2_000

    private let polisher: any DictationTextPolishing
    private let timeout: Duration

    public init(polisher: any DictationTextPolishing, timeout: Duration = Self.timeout) {
        self.polisher = polisher
        self.timeout = timeout
    }

    /// A `recipe` reshapes the text as the user asked; facts are still checked.
    public func callAsFunction(
        _ clean: String, protectedTerms: [String] = [], recipe: String? = nil
    ) async -> DictationPolishOutcome {
        guard DictationPolishFidelity.words(in: clean).count >= Self.minimumWords else { return .kept(.tooShort) }
        guard clean.count <= Self.maximumCharacters else { return .kept(.tooLong) }
        let candidate: String
        do {
            guard let result = try await withDeadline(timeout, { try await polisher.polish(clean, recipe: recipe) })
            else {
                return .kept(.timedOut)
            }
            candidate = result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let unavailable as DictationPolishUnavailable {
            return .kept(.unavailable(unavailable.reason))
        } catch {
            return .kept(.failed)
        }
        if let violation = DictationPolishFidelity.violation(
            original: clean, candidate: candidate, protectedTerms: protectedTerms,
            allowsRestructuring: recipe != nil) {
            return .kept(.changedMeaning(violation))
        }
        return .polished(candidate)
    }

    /// Nil when the deadline wins; the losing branch is cancelled either way.
    private func withDeadline(
        _ limit: Duration, _ operation: @escaping @Sendable () async throws -> String
    ) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return nil }
            return first
        }
    }
}
