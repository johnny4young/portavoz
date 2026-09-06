import SwiftUI

/// Route-owned first actions, without another store, task or capability lookup.
struct LibraryWelcomeView: View {
    let recordingActive: Bool
    let onRecord: () -> Void
    let onAsk: () -> Void

    var body: some View {
        // A split view probes narrow ideal widths during cold layout. Keep text's
        // wrapped intrinsic height inside the viewport rather than making it the
        // minimum height of the entire window (and pushing the sidebar offscreen).
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(maxWidth: 480, alignment: .leading)
                    .padding(32)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(PVDesign.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Your meetings, in focus")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("library-welcome-title")
                Text("Record a conversation, revisit its sources, or ask your library a question.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions }
                VStack(alignment: .leading, spacing: 12) { actions }
            }
            .controlSize(.large)

            Label("Local-first · transfers require opt-in", systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(action: onRecord) {
            Label(
                recordingActive ? LocalizedStringKey("Return to recording") : LocalizedStringKey("New recording"),
                systemImage: recordingActive ? "record.circle" : "plus")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("library-welcome-record")

        Button(action: onAsk) {
            Label("Ask", systemImage: "bubble.left.and.text.bubble.right")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("library-welcome-ask")
    }
}
