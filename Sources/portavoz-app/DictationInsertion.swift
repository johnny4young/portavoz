import ApplicationServices
import Foundation
import PortavozCore

/// Portavoz's own verified insertion: where it is, what it says, and the one way to edit it.
/// A spoken correction may change only this span, and only while it is unchanged.
@MainActor
struct DictationInsertion {
    static let lifetime: TimeInterval = 15 * 60

    let text: String
    let insertedAt: Date
    /// True while the same field still holds exactly this text where it was inserted.
    let isIntact: () -> Bool
    /// Replaces `range` (relative to the insertion) and confirms it; nil when the field refused.
    let edit: (_ range: NSRange, _ replacement: String) async -> DictationInsertion?

    func isFresh(at now: Date) -> Bool { now.timeIntervalSince(insertedAt) < Self.lifetime }

    /// Edits through Accessibility's selected text, never the clipboard or synthesized keys.
    static func accessibility(
        element: AXUIElement, readback: DictationTextReadback,
        validate: @escaping () -> DictationDeliveryOutcome.Refusal?,
        range: NSRange, text: String, now: Date = Date()
    ) -> DictationInsertion {
        let holds = { (span: NSRange, expected: String) in
            readback.string(span).map { $0.utf16.elementsEqual(expected.utf16) } ?? false
        }
        return DictationInsertion(
            text: text, insertedAt: now,
            isIntact: { validate() == nil && holds(range, text) },
            edit: { subrange, replacement in
                guard validate() == nil, holds(range, text) else { return nil }
                var selection = CFRange(location: range.location + subrange.location, length: subrange.length)
                guard let value = AXValueCreate(.cfRange, &selection),
                      AXUIElementSetAttributeValue(
                          element, kAXSelectedTextRangeAttribute as CFString, value) == .success,
                      AXUIElementSetAttributeValue(
                          element, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success
                else { return nil }
                let edited = (text as NSString).replacingCharacters(in: subrange, with: replacement)
                let span = NSRange(location: range.location, length: edited.utf16.count)
                // An editor may apply the change a moment later; never read past that window.
                for _ in 0..<20 {
                    if edited.isEmpty || holds(span, edited) {
                        return accessibility(
                            element: element, readback: readback, validate: validate, range: span, text: edited)
                    }
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return nil }
                }
                return nil
            })
    }
}

/// Holds the destination's latest verified insertion between deliveries.
@MainActor
final class DictationInsertionRecord {
    var value: DictationInsertion?
}
