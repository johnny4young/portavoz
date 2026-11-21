import ApplicationKit
import PortavozCore
import SwiftUI

/// You and the five voices with most talk as pills; everyone else folds into
/// "Others · n", which opens to their pills by talk share.
struct VoiceCastRow<Trailing: View>: View {
    let speakers: [Speaker]
    let cast: VoiceCast
    let onRename: (Speaker) -> Void
    @ViewBuilder let trailing: Trailing
    @State private var showsOthers = false

    var body: some View {
        let byKey = Dictionary(
            speakers.map { (VoiceCast.key($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        FlowLayout(spacing: 8, rowSpacing: 8) {
            ForEach(cast.voices.compactMap { byKey[$0.key] }) { pill($0) }
            if !cast.others.isEmpty {
                othersToggle(count: cast.others.count)
                if showsOthers {
                    ForEach(cast.others.compactMap { byKey[$0.key] }) { pill($0) }
                }
            }
            trailing
        }
    }

    private func pill(_ speaker: Speaker) -> some View {
        SpeakerPill(
            speaker: speaker,
            cast: cast,
            accessibilityIdentifier: "cast-speaker-\(speaker.label)",
            onRename: onRename)
    }

    private func othersToggle(count: Int) -> some View {
        Button {
            showsOthers.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(L10n.format("Others · %d", count))
                Image(systemName: showsOthers ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(PVDesign.ink)
            .pvPill(.clear)
            .overlay { Capsule().strokeBorder(PVDesign.line2, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsOthers ? L10n.text("Expanded") : L10n.text("Collapsed"))
        .accessibilityIdentifier("cast-others")
    }
}
