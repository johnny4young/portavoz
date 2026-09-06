import SwiftUI

/// Presentation-only destinations remain available while an import is working.
struct LibraryNavigationControls: View {
    let route: Route?
    let importing: Bool
    let onImport: () -> Void
    let onNavigate: (Route) -> Void

    var body: some View {
        VStack(spacing: 2) {
            navigationButton(
                "Import", symbol: "square.and.arrow.down", id: "library-import-audio-button",
                help: "Transcribe an audio file (.m4a, .wav, .mp3) as a new meeting",
                busy: importing, action: onImport)
                .disabled(importing)
            Divider().padding(.vertical, 4)
            navigationButton(
                "Ask", symbol: "bubble.left.and.text.bubble.right", id: "library-ask-button",
                help: "Natural-language questions over every meeting, answered on your Mac",
                selected: route == .ask) { onNavigate(.ask) }
            navigationButton(
                "Insights", symbol: "chart.bar.xaxis", id: "library-insights-button",
                help: "Totals, cadence, people and commitments — computed on your Mac",
                selected: route == .insights) { onNavigate(.insights) }
            navigationButton(
                "Radar", symbol: "scope", id: "library-commitment-radar-button",
                help: "Confirmed commitments, deadlines, sources and changes — kept on your Mac",
                selected: route?.isCommitmentRadar == true) { onNavigate(.commitments(nil)) }
        }
    }

    private func navigationButton(
        _ title: LocalizedStringKey, symbol: String, id: String, help: String,
        selected: Bool = false, busy: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(selected ? PVDesign.accent : .secondary)
                    }
                }
                .frame(width: 20)
                .accessibilityHidden(true)
                Text(title)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .contentShape(.rect)
            .background(
                selected ? PVDesign.accent.opacity(PVDesign.chipTint) : .clear,
                in: RoundedRectangle(cornerRadius: PVDesign.radiusSmall))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
        .help(L10n.text(help))
    }
}
