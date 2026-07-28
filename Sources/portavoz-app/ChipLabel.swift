import SwiftUI

/// The suggestion-chip capsule. The DS color-codes chips by their
/// EVIDENCE source — ✦ AI = violet ink with the amber spark, voice match
/// = cyan with the waveform, offer = soft neutral — deliberately distinct
/// from the indigo of ordinary controls, so a suggestion never reads as
/// a button. Wrap in a plain-style Button; the capsule is the whole look.
struct ChipLabel: View {
    enum Kind {
        case ai, voice, offer

        fileprivate var icon: String {
            self == .voice ? "waveform" : "sparkles"
        }

        fileprivate var ink: Color {
            switch self {
            case .ai: PVDesign.chipAIInk
            case .voice: PVDesign.chipVoiceInk
            case .offer: PVDesign.chipOfferInk
            }
        }

        fileprivate var iconInk: Color {
            self == .ai ? PVDesign.chipAISpark : ink
        }

        fileprivate var background: Color {
            switch self {
            case .ai: PVDesign.chipAIBg
            case .voice: PVDesign.chipVoiceBg
            case .offer: PVDesign.chipOfferBg
            }
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
                .foregroundStyle(kind.iconInk)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(kind.ink)
        }
    }
}
