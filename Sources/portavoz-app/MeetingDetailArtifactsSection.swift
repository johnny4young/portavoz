import SwiftUI

/// A bounded home for generated meeting material above the synchronized
/// transcript. Long summaries, commitments, and notes scroll here instead of
/// collapsing the transcript underneath the fixed playback dock.
struct MeetingDetailArtifactsSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 180, idealHeight: 240, maxHeight: 240)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-artifacts-section")
    }
}
