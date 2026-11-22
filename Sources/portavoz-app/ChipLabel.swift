import SwiftUI

/// The kinds of suggestion chip. Anything Portavoz proposes (✦ suggestion,
/// voice match) rides the green tint; an offer stays a soft neutral, so a
/// suggestion never reads as an ink button.
enum ChipLabel {
    /// Marks content Portavoz generated, on and off a chip.
    static let generatedSymbol = "sparkles"

    enum Kind {
        case ai, voice, offer

        fileprivate var icon: String {
            self == .voice ? "waveform" : ChipLabel.generatedSymbol
        }

        fileprivate var ink: Color {
            self == .offer ? PVDesign.chipOfferInk : PVDesign.green
        }

        fileprivate var background: Color {
            self == .offer ? PVDesign.chipOfferBg : PVDesign.greenBg
        }
    }
}

/// One optional recommendation with separate accept and dismiss actions.
/// Keeping the small x inside the capsule makes "ignore this" discoverable
/// without turning a suggestion into an automatic decision.
struct DismissibleSuggestionChip: View {
    let kind: ChipLabel.Kind
    let text: String
    let acceptAccessibilityIdentifier: String
    let dismissAccessibilityIdentifier: String
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: accept) {
                ChipContent(kind: kind, text: text)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(acceptAccessibilityIdentifier)

            ChipCloseButton(
                kind: kind,
                accessibilityLabel: L10n.text("Dismiss suggestion"),
                accessibilityIdentifier: dismissAccessibilityIdentifier,
                action: dismiss)
        }
        .pvPill(kind.background, trailing: 4)
        // A chip keeps its whole text; layouts wrap chips instead of truncating them.
        .fixedSize()
    }
}

private struct ChipContent: View {
    let kind: ChipLabel.Kind
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.icon)
                .font(.caption)
                .foregroundStyle(kind.ink)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(kind.ink)
        }
    }
}

/// A suggestion that was already applied: Undo reverts it, the cross keeps it.
struct UndoableAppliedChip: View {
    let kind: ChipLabel.Kind
    let text: String
    let undoAccessibilityIdentifier: String
    let keepAccessibilityLabel: String
    let keepAccessibilityIdentifier: String
    let undo: () -> Void
    let keep: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ChipContent(kind: kind, text: text)
            Button(L10n.text("Undo"), action: undo)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(PVDesign.accent)
                .accessibilityIdentifier(undoAccessibilityIdentifier)
            ChipCloseButton(
                kind: kind,
                accessibilityLabel: keepAccessibilityLabel,
                accessibilityIdentifier: keepAccessibilityIdentifier,
                action: keep)
        }
        .pvPill(kind.background, trailing: 4)
        // A chip keeps its whole text; layouts wrap chips instead of truncating them.
        .fixedSize()
    }
}

private struct ChipCloseButton: View {
    let kind: ChipLabel.Kind
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(kind.ink.opacity(0.75))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
