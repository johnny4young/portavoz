import SwiftUI

/// Generated meeting material above the synchronized transcript.
///
/// Content decides the height: a short summary takes only the points it
/// needs and the transcript receives everything else. Only when the material
/// outgrows half of the column does it scroll inside its own area, so the
/// transcript stays readable and the playback dock never moves.
struct MeetingDetailArtifactsSection<Content: View>: View {
    /// Height of the column the material shares with the transcript.
    let columnHeight: CGFloat
    @ViewBuilder let content: () -> Content

    /// Half of the column, never below the smallest useful reading area.
    private var heightCap: CGFloat { max(180, columnHeight * 0.5) }

    var body: some View {
        ViewThatFits(in: .vertical) {
            stack
            ScrollView(.vertical) {
                stack
            }
        }
        .frame(maxHeight: heightCap)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-artifacts-section")
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
