import SwiftUI

/// The voice detector heard no speech, so nothing was pasted. The text stays
/// reachable for an explicit Copy in case real speech was missed.
struct DictationNoSpeechView: View {
    let controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No speech detected — nothing was inserted", systemImage: "waveform.slash")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("dictation-panel-delivery-status")
            Text("If you did speak, copy the text below. Nothing was saved in Portavoz.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dictation-panel-delivery-detail")
            ScrollView {
                Text(controller.recoveryText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("dictation-no-speech-text")
            }
            .frame(maxHeight: .infinity)
            DictationCopyStatusLabel(status: controller.copyStatus)
                .accessibilityIdentifier("dictation-no-speech-copy-status")
            HStack(spacing: 8) {
                Button("Copy", action: controller.copyPendingText)
                    .accessibilityIdentifier("dictation-no-speech-copy")
                Spacer()
                Button("Discard", role: .cancel, action: controller.cancel)
                    .accessibilityIdentifier("dictation-no-speech-discard")
            }
            .controlSize(.large)
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
