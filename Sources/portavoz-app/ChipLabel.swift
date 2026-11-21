import SwiftUI

/// The suggestion-chip capsule. Anything Portavoz proposes (✦ suggestion,
/// voice match) rides the green tint; an offer stays a soft neutral, so a
/// suggestion never reads as an ink button. Wrap in a plain-style Button;
/// the capsule is the whole look.
struct ChipLabel: View {
    enum Kind {
        case ai, voice, offer

        fileprivate var icon: String {
            self == .voice ? "waveform" : "sparkles"
        }

        fileprivate var ink: Color {
            self == .offer ? PVDesign.chipOfferInk : PVDesign.green
        }

        fileprivate var background: Color {
            self == .offer ? PVDesign.chipOfferBg : PVDesign.greenBg
        }
    }

    let kind: Kind
    let text: String

    var body: some View {
        ChipContent(kind: kind, text: text)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(kind.background, in: Capsule())
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

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(kind.ink.opacity(0.75))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Dismiss suggestion"))
            .accessibilityIdentifier(dismissAccessibilityIdentifier)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(kind.background, in: Capsule())
    }
}

private struct ChipContent: View {
    let kind: ChipLabel.Kind
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.icon)
                .font(.caption2)
                .foregroundStyle(kind.ink)
            Text(text)
                .font(.caption.weight(.semibold))
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
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(PVDesign.accent)
                .accessibilityIdentifier(undoAccessibilityIdentifier)
            Button(action: keep) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(kind.ink.opacity(0.75))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(keepAccessibilityLabel)
            .accessibilityIdentifier(keepAccessibilityIdentifier)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(kind.background, in: Capsule())
    }
}
