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
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if !hasLoaded {
                Section("Remembered voices") {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            } else if !voices.isEmpty || errorMessage != nil {
                Section("Remembered voices") {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settings-remembered-voices-error")
                        HStack {
                            Button("Try again") {
                                Task { await reload() }
                            }
                            .accessibilityIdentifier("settings-remembered-voices-retry")
                            Button("Forget all voices", role: .destructive) {
                                removeAll()
                            }
                            .accessibilityIdentifier("settings-remembered-voices-delete-all")
                        }
                    }
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
                    if errorMessage == nil {
                        Button("Forget all voices", role: .destructive) {
                            removeAll()
                        }
                        .accessibilityIdentifier("settings-remembered-voices-delete-all")
                    }
                    if !voices.isEmpty {
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
        }
        .task { await reload() }
    }

    private func reload() async {
        defer { hasLoaded = true }
        do {
            voices = try await services.rememberedVoiceSummaries()
            errorMessage = nil
        } catch {
            errorMessage = L10n.text(
                "Stored remembered voices could not be opened. Nothing was changed.")
        }
    }

    private func remove(_ id: UUID) {
        Task {
            do {
                try await services.removeRememberedVoice(id: id)
                await reload()
            } catch {
                errorMessage = L10n.text(
                    "Stored remembered voices could not be opened. Nothing was changed.")
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
                errorMessage = L10n.text(
                    "Could not delete all remembered voices. Nothing was reported as deleted; try again.")
            }
        }
    }
}
