import SwiftUI

/// The Ask entry in Today's title bar. Its leading glyph opens three ready
/// questions; submitting hands the text to the Ask surface exactly as a
/// suggestion does.
struct HomeAskField: View {
    let suggestions: [String]
    let onAsk: (String?) -> Void

    @State private var question = ""

    var body: some View {
        HStack(spacing: PVDesign.space2) {
            Menu {
                ForEach(Array(suggestions.prefix(3).enumerated()), id: \.offset) { index, suggestion in
                    let question = L10n.text(suggestion)
                    Button(question) { onAsk(question) }
                    .accessibilityIdentifier("home-ask-chip-\(index)")
                }
            } label: {
                Image(systemName: PVSymbol.ask)
                    .foregroundStyle(PVDesign.ink3)
            }
            // A plain button menu draws the bare glyph; borderless adds a tinted bezel.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Suggested questions")
            .accessibilityLabel(L10n.text("Suggested questions"))
            .accessibilityIdentifier("home-ask-suggestions")
            TextField("Ask your meetings…", text: $question)
                .textFieldStyle(.plain)
                .onSubmit(submit)
                .accessibilityIdentifier("home-ask-field")
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(PVDesign.onInk)
                    .frame(width: 22, height: 22)
                    .background(PVDesign.ink, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Ask"))
            .accessibilityIdentifier("home-ask")
        }
        .padding(.leading, PVDesign.space3)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(PVDesign.raise, in: Capsule())
        .overlay(Capsule().strokeBorder(PVDesign.line2, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-ask-section")
    }

    private func submit() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        onAsk(trimmed.isEmpty ? nil : trimmed)
        question = ""
    }
}
