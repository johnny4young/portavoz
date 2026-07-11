import DiarizationKit
import SwiftUI

/// Settings section: voices of OTHER participants the user explicitly
/// asked to remember (D8: stricter rules than "My voice" — see
/// `VoiceGallery`). Self-contained: it loads its own list, shows nothing
/// while the gallery is empty, and voices only ever enter the gallery via
/// the "Remember this voice" chip in a meeting.
struct RememberedVoicesSection: View {
    @State private var voices: [RememberedVoice] = []

    var body: some View {
        Group {
            if !voices.isEmpty {
                Section("Remembered voices") {
                    ForEach(voices) { voice in
                        LabeledContent(
                            voice.name,
                            value: voice.createdAt.formatted(date: .abbreviated, time: .omitted)
                        )
                        .contextMenu {
                            Button(L10n.format("Forget %@", voice.name), role: .destructive) {
                                try? VoiceGallery().remove(id: voice.id)
                                reload()
                            }
                        }
                    }
                    Button("Forget all voices", role: .destructive) {
                        try? VoiceGallery().deleteAll()
                        voices = []
                    }
                    Text(
                        // One-line UI help text.
                        // swiftlint:disable:next line_length
                        "Encrypted numeric fingerprints of voices you chose to remember, used only to suggest names in future meetings — never audio, never synced. Right-click a name to forget one voice."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        guard !ProcessInfo.processInfo.arguments.contains("-use-temp-store") else { return }
        voices = (try? VoiceGallery().voices()) ?? []
    }
}
