import Foundation

/// Canonical outline of immutable summary Markdown. Storage uses the bullet
/// positions to validate typed decision evidence; ApplicationKit uses the
/// same parse to build language-independent summary tabs.
public struct SummaryMarkdownOutline: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        public let heading: String
        public let body: String
        public let bulletLines: [String]

        public init(heading: String, body: String, bulletLines: [String]) {
            self.heading = heading
            self.body = body
            self.bulletLines = bulletLines
        }
    }

    public let intro: String
    public let sections: [Section]

    public init(intro: String, sections: [Section]) {
        self.intro = intro
        self.sections = sections
    }

    public static func parse(_ markdown: String) -> SummaryMarkdownOutline {
        var intro: [String] = []
        var sections: [Section] = []
        var currentHeading: String?
        var currentBody: [String] = []

        func flush() {
            guard let heading = currentHeading else { return }
            let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .newlines)
            sections.append(Section(
                heading: heading,
                body: body,
                bulletLines: currentBody.filter(isBulletLine)))
            currentBody = []
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                flush()
                currentHeading = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("# ") {
                continue
            } else if currentHeading == nil {
                intro.append(line)
            } else {
                currentBody.append(line)
            }
        }
        flush()

        return SummaryMarkdownOutline(
            intro: intro.joined(separator: "\n").trimmingCharacters(in: .newlines),
            sections: sections)
    }

    private static func isBulletLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return ["- ", "* ", "· ", "▸ "].contains(where: trimmed.hasPrefix)
    }
}
