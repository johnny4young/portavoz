import SwiftUI

/// Evaluates its content in its own body, so what the content observes (the
/// toolbar's trim offer reads the playback duration) invalidates only this view.
struct MeetingDetailScopedContent<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}
