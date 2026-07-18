import ApplicationKit
import SwiftUI

/// Settings section: voices of OTHER participants the user explicitly
/// asked to remember (D8: stricter rules than "My voice" — see
/// the encrypted voice gallery). It loads its own list, shows nothing
/// while the gallery is empty, and voices only ever enter the gallery via
/// the "Remember this voice" chip in a meeting.
struct RememberedVoicesSection: View {
    @Environment(AppServices.self) private var services
    @State private var voices: [RememberedVoiceSummary] = []
    @State private var errorMessage: String?

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
                                remove(voice.id)
                            }
                        }
                    }
                    Button("Forget all voices", role: .destructive) {
                        removeAll()
                    }
                    .accessibilityIdentifier("settings-remembered-voices-delete-all")
                    Text(
                        // One-line UI help text.
                        // swiftlint:disable:next line_length
                        "Encrypted numeric fingerprints of voices you chose to remember, used only to suggest names in future meetings — never audio, never synced. Right-click a name to forget one voice."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settings-remembered-voices-error")
                    }
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        do {
            voices = try await services.rememberedVoiceSummaries()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ id: UUID) {
        Task {
            do {
                try await services.removeRememberedVoice(id: id)
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeAll() {
        Task {
            do {
                try await services.removeAllRememberedVoices()
                voices = []
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
