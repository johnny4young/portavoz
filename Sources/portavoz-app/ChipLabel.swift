import SwiftUI

/// The suggestion-chip capsule. The DS color-codes chips by their
/// EVIDENCE source — ✦ AI = violet ink with the amber spark, voice match
/// = cyan with the waveform, offer = soft neutral — deliberately distinct
/// from the indigo of ordinary controls, so a suggestion never reads as
/// a button. Wrap in a plain-style Button; the capsule is the whole look.
struct ChipLabel: View {
    enum Kind {
        case ai, voice, offer
    }

    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind == .voice ? "waveform" : "sparkles")
                .font(.caption2)
                .foregroundStyle(kind == .ai ? PVDesign.chipAISpark : ink)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ink)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
    }

    private var ink: Color {
        switch kind {
        case .ai: PVDesign.chipAIInk
        case .voice: PVDesign.chipVoiceInk
        case .offer: PVDesign.chipOfferInk
        }
    }

    private var background: Color {
        switch kind {
        case .ai: PVDesign.chipAIBg
        case .voice: PVDesign.chipVoiceBg
        case .offer: PVDesign.chipOfferBg
        }
    }
}
