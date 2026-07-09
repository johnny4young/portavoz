import SwiftUI

/// Block-level markdown for our own documents (headings, bullets,
/// checkboxes, quotes) with inline styling (**bold**, *italic*, `code`)
/// via AttributedString. Covers exactly what Portavoz generates; a full
/// CommonMark renderer would be a dependency without a payoff here.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(
                Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                id: \.offset
            ) { _, rawLine in
                let line = String(rawLine)
                if line.hasPrefix("# ") {
                    Text(inline(String(line.dropFirst(2))))
                        .font(.title2.bold())
                        .padding(.top, 4)
                } else if line.hasPrefix("## ") {
                    Text(inline(String(line.dropFirst(3))))
                        .font(.headline)
                        .padding(.top, 8)
                } else if line.hasPrefix("### ") {
                    Text(inline(String(line.dropFirst(4))))
                        .font(.subheadline.bold())
                        .padding(.top, 6)
                } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [ ] ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: line.hasPrefix("- [x] ") ? "checkmark.square" : "square")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                        Text(inline(String(line.dropFirst(6))))
                            .strikethrough(line.hasPrefix("- [x] "))
                    }
                } else if line.hasPrefix("- ▸ ") {
                    // Coauthoring (D28): a bullet born from one of your notes.
                    // Granola-style: the marker distinguishes it from a pure
                    // AI summary ("this came from what YOU flagged").
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("▸").foregroundStyle(.tint)
                        Text(inline(String(line.dropFirst(4))))
                            .fontWeight(.medium)
                    }
                } else if line.hasPrefix("- ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(String(line.dropFirst(2))))
                    }
                } else if line.hasPrefix("> ") {
                    Text(inline(String(line.dropFirst(2))))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !line.isEmpty {
                    Text(inline(line))
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ line: String) -> AttributedString {
        (try? AttributedString(
            markdown: line,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
    }
}
