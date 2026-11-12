import Foundation

/// Translates one short text (a dictation, a transcript line) with the system's on-device translator.
public protocol TextTranslating: Sendable {
    /// Throws `TranslationUnavailable` when the language pair cannot run now.
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}

public struct TranslationUnavailable: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case notInstalled, unsupported }
    public let reason: Reason

    public init(_ reason: Reason) {
        self.reason = reason
    }
}

/// Why a text was kept untranslated.
public enum TranslationSkip: Equatable, Sendable {
    case sameLanguage
    case unknownLanguage
    case notInstalled
    case unsupported
    case timedOut
    case failed
}

public enum TranslationOutcome: Equatable, Sendable {
    case translated(String)
    case kept(TranslationSkip)
}

/// Every failure keeps the text as it was: it comes back translated or untouched.
public struct TranslateText: Sendable {
    public static let timeout: Duration = .seconds(5)

    private let translator: any TextTranslating
    private let timeout: Duration

    public init(translator: any TextTranslating, timeout: Duration = Self.timeout) {
        self.translator = translator
        self.timeout = timeout
    }

    /// `source` is the text's language, or nil when it was not set and could not be detected.
    public func callAsFunction(_ text: String, source: String?, target: String) async -> TranslationOutcome {
        guard let source else { return .kept(.unknownLanguage) }
        guard source != target else { return .kept(.sameLanguage) }
        do {
            let translator = translator
            let result = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { try await translator.translate(text, from: source, to: target) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { return String?.none }
                return first
            }
            guard let translated = result?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return .kept(.timedOut)
            }
            return translated.isEmpty ? .kept(.failed) : .translated(translated)
        } catch let unavailable as TranslationUnavailable {
            return .kept(unavailable.reason == .notInstalled ? .notInstalled : .unsupported)
        } catch {
            return .kept(.failed)
        }
    }
}
