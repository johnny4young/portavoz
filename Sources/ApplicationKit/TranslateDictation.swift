import Foundation

/// Translates one dictation with the system's on-device translator.
public protocol DictationTextTranslating: Sendable {
    /// Throws `DictationTranslationUnavailable` when the language pair cannot run now.
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}

public struct DictationTranslationUnavailable: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case notInstalled, unsupported }
    public let reason: Reason

    public init(_ reason: Reason) {
        self.reason = reason
    }
}

/// Why a dictation was pasted untranslated.
public enum DictationTranslationSkip: Equatable, Sendable {
    case sameLanguage
    case unknownLanguage
    case notInstalled
    case unsupported
    case timedOut
    case failed
}

public enum DictationTranslationOutcome: Equatable, Sendable {
    case translated(String)
    case kept(DictationTranslationSkip)
}

/// Every failure keeps the text as it was: a dictation is pasted translated or untouched.
public struct TranslateDictation: Sendable {
    public static let timeout: Duration = .seconds(5)

    private let translator: any DictationTextTranslating
    private let timeout: Duration

    public init(translator: any DictationTextTranslating, timeout: Duration = Self.timeout) {
        self.translator = translator
        self.timeout = timeout
    }

    /// `source` is the dictation language, or nil when it was not set and could not be detected.
    public func callAsFunction(_ text: String, source: String?, target: String) async -> DictationTranslationOutcome {
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
        } catch let unavailable as DictationTranslationUnavailable {
            return .kept(unavailable.reason == .notInstalled ? .notInstalled : .unsupported)
        } catch {
            return .kept(.failed)
        }
    }
}
