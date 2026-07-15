import PortavozCore
import SwiftUI

// The Intelligence pane's transcript/output language policies and the
// custom-structure manager — split out to keep SettingsView.swift small.
extension SettingsView {
    var transcriptionLanguageSection: some View {
        Section("Transcription language") {
            Picker("Spoken language", selection: $transcriptionLanguage) {
                Text("Auto-detect").tag("auto")
                Text("English").tag("en")
                Text("Español").tag("es")
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings-transcription-language")
            Text(
                // One-line UI help.
                // swiftlint:disable:next line_length
                "Auto-detect preserves each speaker's language in mixed meetings. Pin one language only when quiet or noisy audio was detected incorrectly."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    var summaryLanguageSection: some View {
        Section("Summary language") {
            Picker("Write summaries in", selection: $summaryLanguage) {
                Text("Meeting language").tag(SummaryLanguagePolicy.followSpokenLanguage.persistedValue)
                Text("English").tag(SummaryLanguagePolicy.fixed(.english).persistedValue)
                Text("Español").tag(SummaryLanguagePolicy.fixed(.spanish).persistedValue)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings-summary-language")
            Text(
                // One-line UI help.
                // swiftlint:disable:next line_length
                "This changes generated summaries only. Transcript language is controlled separately above and is never changed by this setting."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    var customStructuresSection: some View {
        Section("Custom structures") {
            if customStructures.isEmpty {
                Text(
                    // One-line UI help.
                    // swiftlint:disable:next line_length
                    "Create your own summary shapes — a Hangout, a Brainstorm — beyond the five built-ins. They appear in a meeting's Structure menu."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(customStructures) { recipe in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(recipe.displayName)
                        Text(recipe.sections.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        editingStructure = recipe
                        showingStructureSheet = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    Button {
                        CustomRecipeStore.delete(id: recipe.id)
                        customStructures = CustomRecipeStore.custom()
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add structure") {
                editingStructure = nil
                showingStructureSheet = true
            }
            .accessibilityIdentifier("settings-add-structure")
        }
    }
}
