import PortavozCore
import SwiftUI

// The Intelligence pane's transcription-language pin and the custom-structure
// manager — split out to keep SettingsView.swift under the length limit.
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
                "Pin the language you speak so a quiet or noisy recording is never transcribed in the wrong language. Auto-detect works well with clear audio."
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
