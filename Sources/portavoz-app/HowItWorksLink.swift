import SwiftUI

/// The one place a long explanation lives in Settings: a caption stays one
/// line, and the paragraph opens on demand instead of taking pane height.
struct HowItWorksLink: View {
    let text: String
    let identifier: String

    @State private var showsExplanation = false

    var body: some View {
        Button {
            showsExplanation.toggle()
        } label: {
            Label("How it works", systemImage: "info.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(PVDesign.accent)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $showsExplanation, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .padding(16)
                .accessibilityIdentifier("\(identifier)-popover")
        }
    }
}
