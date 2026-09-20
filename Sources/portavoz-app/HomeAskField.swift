import SwiftUI

/// The Ask entry on Today: one field with three ready questions under it.
/// The typed text is the only state here; submitting hands it to the Ask
/// surface exactly as the chips do.
struct HomeAskField: View {
    let suggestions: [String]
    let onAsk: (String?) -> Void

    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: PVDesign.space2) {
            HStack(spacing: PVDesign.space2) {
                Image(systemName: PVSymbol.ask)
                    .foregroundStyle(PVDesign.accent)
                    .accessibilityHidden(true)
                TextField("Ask your meetings…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit(submit)
                    .accessibilityIdentifier("home-ask-field")
                Button(action: submit) {
                    Label("Ask", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PVDesign.accent)
                .accessibilityLabel(L10n.text("Ask"))
                .accessibilityIdentifier("home-ask")
            }
            .padding(.horizontal, PVDesign.space3)
            .padding(.vertical, PVDesign.space2)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: PVDesign.radiusCard))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PVDesign.space2) { chips }
                VStack(alignment: .leading, spacing: PVDesign.space2) { chips }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-ask-section")
    }

    private var chips: some View {
        ForEach(Array(suggestions.prefix(3).enumerated()), id: \.offset) { index, question in
            Button {
                onAsk(L10n.text(question))
            } label: {
                Text(L10n.text(question))
                    .font(.callout)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(PVDesign.accent.opacity(PVDesign.chipTint), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home-ask-chip-\(index)")
        }
    }

    private func submit() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        onAsk(trimmed.isEmpty ? nil : trimmed)
        question = ""
    }
}
