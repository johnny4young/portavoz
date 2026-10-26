import Foundation

/// Verification reads only the proposed insertion's span. The other reads are
/// at most `contextLength` units on each side of the selection, to space the
/// insertion; none is kept. The whole external document is never needed.
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
    /// One character, or one surrogate pair or combining sequence.
    static let contextLength = 2

    let position: () -> Position?
    let string: (NSRange) -> String?
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }
    var pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(25)) }
    /// Nil means the editor's text around the selection is never requested.
    var context: ((NSRange) -> String?)?
    /// Opt-in: reads more of the text before the caret to match the first word's case.
    var caretCase: DictationCaretCase?

    func baseline(for text: String) -> Position? {
        guard Self.admitsLength(of: text), let value = position() else { return nil }
        return baseline(for: text, at: value)
    }

    /// The exact output for this field and its baseline. `admits` revalidates
    /// the field (focus, secure input) immediately before any text is requested.
    func prepare(_ text: String, admits: () -> Bool) -> (text: String, baseline: Position?) {
        guard Self.admitsLength(of: text), let value = position(), value.isValid else { return (text, nil) }
        guard let context, admits() else { return (text, baseline(for: text, at: value)) }
        let start = value.selection.location
        let end = start + value.selection.length
        let beforeLength = min(caretCase == nil ? Self.contextLength : DictationCaretCase.contextLength, start)
        let afterLength = min(Self.contextLength, value.characterCount - end)
        let before = beforeLength == 0 ? "" : context(NSRange(location: start - beforeLength, length: beforeLength))
        let after = afterLength == 0 ? "" : context(NSRange(location: end, length: afterLength))
        let cased = before.flatMap { preceding in
            caretCase?.adapt(text, after: preceding, atFieldStart: beforeLength == start)
        } ?? text
        let output = DictationCaretJoin.join(cased, after: before, before: after)
        return (output, baseline(for: output, at: value))
    }

    private static func admitsLength(of text: String) -> Bool {
        let length = text.utf16.count
        return length > 0 && length <= maximumUTF16Length
    }

    private func baseline(for text: String, at value: Position) -> Position? {
        let length = text.utf16.count
        guard Self.admitsLength(of: text), value.isValid,
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
