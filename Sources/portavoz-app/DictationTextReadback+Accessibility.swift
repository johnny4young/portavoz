import ApplicationServices
import Foundation

extension DictationTextReadback {
    static func accessibility(_ element: AXUIElement) -> Self? {
        // Timeout applies to this exact AX object, not equal instances or all
        // clients. Do not change the process-global system-wide timeout.
        guard AXUIElementSetMessagingTimeout(element, 0.1) == .success else { return nil }
        return Self(position: {
            guard let rangeValue = attribute(kAXSelectedTextRangeAttribute, of: element),
                  let range = TextInserter.checkedCFValue(rangeValue, as: .accessibilityValue),
                  AXValueGetType(range) == .cfRange,
                  let countValue = attribute(kAXNumberOfCharactersAttribute, of: element),
                  let count = characterCount(countValue) else { return nil }
            var selection = CFRange()
            guard AXValueGetValue(range, .cfRange, &selection) else { return nil }
            return Position(selection: NSRange(location: selection.location, length: selection.length),
                            characterCount: count)
        }, string: { span in
            var range = CFRange(location: span.location, length: span.length)
            guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
                  let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
            return value as? String
        })
    }

    static func characterCount(_ value: CFTypeRef) -> Int? {
        guard let number = TextInserter.checkedCFValue(value, as: .number) else { return nil }
        // CFNumberGetValue's integer conversion and NSNumber equality can both
        // accept Double(2^63) as Int.max. Swift's exact floating conversion must
        // fence that boundary before any native-index conversion.
        if CFNumberIsFloatType(number) {
            var floating = 0.0
            guard CFNumberGetValue(number, .doubleType, &floating),
                  let count = Int(exactly: floating), count >= 0 else { return nil }
            return count
        }
        var count = 0
        guard CFNumberGetValue(number, .cfIndexType, &count), count >= 0 else { return nil }
        return count
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
