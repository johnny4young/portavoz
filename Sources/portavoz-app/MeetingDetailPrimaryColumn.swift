import SwiftUI

/// Gives the transcript and generated material separate reading space when
/// their combined minimum heights cannot fit above the docked player.
struct MeetingDetailPrimaryColumn<Material: View, Transcript: View, Player: View>: View {
    let columnHeight: CGFloat
    @Binding var selectedPane: MeetingDetailReadingPane
    @ViewBuilder let material: () -> Material
    @ViewBuilder let transcript: () -> Transcript
    @ViewBuilder let player: () -> Player

    @State private var playerHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if MeetingDetailPrimaryColumnLayout.usesFocusedPane(
                columnHeight: columnHeight,
                playerHeight: playerHeight
            ) {
                compactPaneSelector
                Group {
                    switch selectedPane {
                    case .summary:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                material()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("detail-artifacts-section")
                    case .transcript:
                        transcript()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
            } else {
                MeetingDetailArtifactsSection(columnHeight: columnHeight) {
                    material()
                }
                transcript()
                    .layoutPriority(1)
            }
            player()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    playerHeight = height
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var compactPaneSelector: some View {
        HStack(spacing: 8) {
            Button("Transcript") { selectedPane = .transcript }
                .accessibilityIdentifier("detail-compact-transcript")
                .accessibilityAddTraits(selectedPane == .transcript ? .isSelected : [])
                .tint(selectedPane == .transcript ? PVDesign.accent : .gray)
            Button("Summary") { selectedPane = .summary }
                .accessibilityIdentifier("detail-compact-summary")
                .accessibilityAddTraits(selectedPane == .summary ? .isSelected : [])
                .tint(selectedPane == .summary ? PVDesign.accent : .gray)
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

}

enum MeetingDetailReadingPane {
    case transcript
    case summary
}

enum MeetingDetailPrimaryColumnLayout {
    private static let minimumMaterialHeight: CGFloat = 180
    private static let minimumTranscriptHeight: CGFloat = 160
    private static let sectionSpacing: CGFloat = 10

    static func usesFocusedPane(columnHeight: CGFloat, playerHeight: CGFloat) -> Bool {
        columnHeight < minimumMaterialHeight + minimumTranscriptHeight
            + playerHeight + (sectionSpacing * 2)
    }
}
