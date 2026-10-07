import Foundation

/// Reads only the proposed insertion's span. Neither the previous selection's
/// text nor the whole external document is needed to verify an observed edit.
@MainActor
struct DictationTextReadback {
    struct Position: Equatable {
        let selection: NSRange
        let characterCount: Int

        var isValid: Bool {
            characterCount >= 0 && selection.location >= 0 && selection.location != NSNotFound
                && selection.length >= 0 && selection.location <= characterCount
                && selection.length <= characterCount - selection.location
        }
    }

    // A verification bound, not a dictation-length limit: longer output is
    // still sent in full, but is never materialized from an external AX server.
    static let maximumUTF16Length = 16_384
    static let observationWindow: Duration = .milliseconds(750)

    let position: () -> Position?
    let string: (NSRange) -> String?
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }
    var pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(25)) }

    func baseline(for text: String) -> Position? {
        let length = text.utf16.count
        guard length > 0, length <= Self.maximumUTF16Length,
              let value = position(), value.isValid,
              length <= Int.max - (value.characterCount - value.selection.length),
              length <= Int.max - value.selection.location else { return nil }
        return value
    }

    func verify(_ text: String, from baseline: Position, target: TextInserter.Target) async -> Bool {
        let length = text.utf16.count
        let expected = Position(selection: NSRange(location: baseline.selection.location + length, length: 0),
                                characterCount: baseline.characterCount - baseline.selection.length + length)
        let span = NSRange(location: baseline.selection.location, length: length)
        let deadline = now().advanced(by: Self.observationWindow)
        // Both the deadline and attempt count bound even an injected or stalled
        // clock. AX has its own per-message timeout, not a real-time guarantee.
        for _ in 0..<30 {
            guard !Task.isCancelled, now() < deadline, target.validate() == nil,
                  !Task.isCancelled, now() < deadline else { return false }
            guard let current = position(), current.isValid, !Task.isCancelled, now() < deadline else { return false }
            if current == expected {
                // Metadata IPC may have serviced a secure-field/focus change.
                // Revalidate before asking the server for any actual text.
                guard target.validate() == nil, !Task.isCancelled, now() < deadline else { return false }
                let observed = string(span)
                guard !Task.isCancelled, now() < deadline,
                      target.validate() == nil, !Task.isCancelled, now() < deadline,
                      position() == expected, !Task.isCancelled, now() < deadline,
                      target.validate() == nil, !Task.isCancelled, now() < deadline else { return false }
                // Exact code units: typographic substitutions and normalization
                // are not confirmation of the literal output we sent.
                return observed.map { $0.utf16.elementsEqual(text.utf16) } ?? false
            }
            // A still-unchanged editor may simply not have serviced Paste yet.
            // Any other shape is ambiguous; never read a different span.
            guard current == baseline else { return false }
            do { try await pause() } catch { return false }
        }
        return false
    }
}
