import SwiftUI

/// Generated meeting material above the synchronized transcript.
///
/// Content decides the height: the area measures its own material and takes
/// exactly that many points, so a short summary leaves the transcript most of
/// the column. Only when the material outgrows half of the column does it
/// scroll inside its own area, so the transcript stays readable and the
/// playback dock never moves.
struct MeetingDetailArtifactsSection<Content: View>: View {
    /// Height of the column the material shares with the transcript.
    let columnHeight: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat = 0

    /// Half of the column on a tall window; on a short one the transcript and
    /// the playback dock keep their room first, and the material falls back to
    /// the smallest useful reading area (the pre-1.1 floor).
    private var heightCap: CGFloat {
        max(180, min(columnHeight * 0.5, columnHeight - 360))
    }

    /// The measured material, bounded by the cap; a not-yet-measured area
    /// keeps the smallest useful height so the first layout is never empty.
    private var resolvedHeight: CGFloat {
        contentHeight > 0 ? min(contentHeight, heightCap) : 180
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                contentHeight = height
            }
        }
        .frame(height: resolvedHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-artifacts-section")
    }
}
