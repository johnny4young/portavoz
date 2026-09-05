import Foundation
import PortavozCore

struct AskWebParsedDocument: Equatable {
    let title: String?
    let observedDate: Date?
    let text: String
    let isTruncated: Bool
}

enum AskWebDocumentParser {
    private static let hiddenElements = Set([
        "script", "style", "noscript", "svg", "template"
    ])
    private static let blockElements = Set([
        "article", "aside", "blockquote", "br", "div", "footer", "h1",
        "h2", "h3", "h4", "h5", "h6", "header", "li", "main", "nav",
        "ol", "p", "section", "table", "td", "th", "tr", "ul"
    ])

    static func parse(_ data: Data) -> AskWebParsedDocument {
        let source = (String(data: data, encoding: .utf8) ?? "")
            .replacingOccurrences(of: "\0", with: "")
        var text = ""
        var title = ""
        var tag = ""
        var isInsideTag = false
        var isInsideTitle = false
        var hiddenStack: [String] = []
        var observedDate: Date?

        func appendVisible(_ character: Character) {
            guard hiddenStack.isEmpty else { return }
            if isInsideTitle {
                title.append(character)
            } else {
                text.append(character)
            }
        }

        for character in source {
            if isInsideTag {
                if character == ">" {
                    handle(
                        tag,
                        hiddenStack: &hiddenStack,
                        isInsideTitle: &isInsideTitle,
                        text: &text,
                        observedDate: &observedDate)
                    tag.removeAll(keepingCapacity: true)
                    isInsideTag = false
                } else if tag.count < 2_048 {
                    tag.append(character)
                }
            } else if character == "<" {
                isInsideTag = true
            } else {
                appendVisible(character)
            }
        }

        let normalizedTitle = normalize(title)
        let normalizedText = normalize(text)
        let bounded = bound(normalizedText)
        return AskWebParsedDocument(
            title: normalizedTitle.isEmpty
                ? nil
                : String(normalizedTitle.prefix(
                    AskWebEvidenceLimits.maximumTitleCharacters)),
            observedDate: observedDate,
            text: bounded.text,
            isTruncated: bounded.isTruncated)
    }

    private static func handle(
        _ rawTag: String,
        hiddenStack: inout [String],
        isInsideTitle: inout Bool,
        text: inout String,
        observedDate: inout Date?
    ) {
        let trimmed = rawTag.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("!") && !trimmed.hasPrefix("?")
        else { return }
        let isClosing = trimmed.hasPrefix("/")
        let body = isClosing ? trimmed.dropFirst() : Substring(trimmed)
        let name = body.prefix { !$0.isWhitespace && $0 != "/" }
            .lowercased()
        guard !name.isEmpty else { return }

        if isClosing {
            if name == "title" { isInsideTitle = false }
            if let index = hiddenStack.lastIndex(of: name) {
                hiddenStack.removeSubrange(index...)
            }
        } else {
            if name == "title" { isInsideTitle = true }
            if hiddenElements.contains(name) { hiddenStack.append(name) }
            if hiddenStack.isEmpty,
               observedDate == nil,
               name == "time",
               let value = attribute("datetime", in: trimmed),
               let date = ISO8601DateFormatter().date(from: value) {
                observedDate = date
            }
        }
        if blockElements.contains(name), !text.hasSuffix(" ") {
            text.append(" ")
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        var index = tag.startIndex
        skipToken(in: tag, index: &index)
        while let candidate = nextQuotedAttribute(in: tag, index: &index) {
            if candidate.name.caseInsensitiveCompare(name) == .orderedSame {
                return candidate.value
            }
        }
        return nil
    }

    private static func nextQuotedAttribute(
        in tag: String,
        index: inout String.Index
    ) -> (name: String, value: String)? {
        while index < tag.endIndex {
            skipWhitespace(in: tag, index: &index)
            guard index < tag.endIndex, tag[index] != "/" else { return nil }
            guard let attributeName = readAttributeName(in: tag, index: &index)
            else {
                index = tag.index(after: index)
                continue
            }
            skipWhitespace(in: tag, index: &index)
            guard index < tag.endIndex, tag[index] == "=" else { continue }
            index = tag.index(after: index)
            skipWhitespace(in: tag, index: &index)
            guard let value = readQuotedValue(in: tag, index: &index) else {
                skipToken(in: tag, index: &index)
                continue
            }
            return (String(attributeName), value)
        }
        return nil
    }

    private static func readAttributeName(
        in tag: String,
        index: inout String.Index
    ) -> Substring? {
        let start = index
        while index < tag.endIndex,
              !tag[index].isWhitespace,
              tag[index] != "=",
              tag[index] != "/" {
            index = tag.index(after: index)
        }
        return start < index ? tag[start..<index] : nil
    }

    private static func readQuotedValue(
        in tag: String,
        index: inout String.Index
    ) -> String? {
        guard index < tag.endIndex,
              tag[index] == "\"" || tag[index] == "'"
        else { return nil }
        let quote = tag[index]
        let valueStart = tag.index(after: index)
        guard let valueEnd = tag[valueStart...].firstIndex(of: quote) else {
            index = tag.endIndex
            return nil
        }
        index = tag.index(after: valueEnd)
        return String(tag[valueStart..<valueEnd])
    }

    private static func skipWhitespace(
        in tag: String,
        index: inout String.Index
    ) {
        while index < tag.endIndex, tag[index].isWhitespace {
            index = tag.index(after: index)
        }
    }

    private static func skipToken(
        in tag: String,
        index: inout String.Index
    ) {
        while index < tag.endIndex, !tag[index].isWhitespace {
            index = tag.index(after: index)
        }
    }

    private static func normalize(_ value: String) -> String {
        decodeEntities(value)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func decodeEntities(_ value: String) -> String {
        var result = value
        let named = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&nbsp;": " "
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(
                of: entity,
                with: replacement,
                options: .caseInsensitive)
        }
        return result
    }

    private static func bound(_ value: String) -> (text: String, isTruncated: Bool) {
        var text = ""
        text.reserveCapacity(min(
            value.count,
            AskWebEvidenceLimits.maximumTextCharacters))
        var characters = 0
        var bytes = 0
        for character in value {
            let width = String(character).utf8.count
            guard characters < AskWebEvidenceLimits.maximumTextCharacters,
                  bytes + width <= AskWebEvidenceLimits.maximumTextUTF8Bytes
            else { return (text, true) }
            text.append(character)
            characters += 1
            bytes += width
        }
        return (text, false)
    }
}
