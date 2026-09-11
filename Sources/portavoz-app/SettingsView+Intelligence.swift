import PortavozCore
import SwiftUI

// The Intelligence pane's transcript/output language policies and the
// custom-structure manager — split out to keep SettingsView.swift small.
extension SettingsView {
    var semanticSearchSection: some View {
        let model = services.semanticSearchPreparation
        return Section("Semantic search") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: semanticSearchStatusIcon(model.phase))
                    .font(.title2)
                    .foregroundStyle(semanticSearchStatusTint(model.phase))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(semanticSearchStatusTitle(model.phase))
                            .font(.headline)
                            .accessibilityIdentifier(
                                "settings-semantic-search-status-"
                                    + semanticSearchStatusIdentifier(model.phase))
                        if model.phase == .checking || model.phase == .preparing {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text(semanticSearchStatusDetail(model.phase))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.vertical, 4)

            if semanticSearchCanPrepare(model.phase) {
                Button {
                    Task { await model.prepare() }
                } label: {
                    Label(
                        model.phase == .needsPreparation
                            ? L10n.text("Prepare semantic search")
                            : L10n.text("Try again"),
                        systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("settings-semantic-search-prepare")
            }
        }
        .task { await model.refresh() }
    }

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

    private func semanticSearchCanPrepare(
        _ phase: SemanticSearchPreparationModel.Phase
    ) -> Bool {
        switch phase {
        case .needsPreparation, .blockedByCapture, .failed:
            true
        case .checking, .preparing, .ready, .unsupported:
            false
        }
    }

    private func semanticSearchStatusIdentifier(
        _ phase: SemanticSearchPreparationModel.Phase
    ) -> String {
        switch phase {
        case .checking: "checking"
        case .needsPreparation: "needs-preparation"
        case .preparing: "preparing"
        case .ready: "ready"
        case .unsupported: "unsupported"
        case .blockedByCapture: "blocked-by-capture"
        case .failed: "failed"
        }
    }

    private func semanticSearchStatusIcon(
        _ phase: SemanticSearchPreparationModel.Phase
    ) -> String {
        switch phase {
        case .checking, .preparing: "arrow.triangle.2.circlepath"
        case .needsPreparation: "sparkles"
        case .ready: "checkmark.circle.fill"
        case .unsupported: "minus.circle"
        case .blockedByCapture: "waveform.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func semanticSearchStatusTint(
        _ phase: SemanticSearchPreparationModel.Phase
    ) -> Color {
        switch phase {
        case .ready: .green
        case .blockedByCapture: .orange
        case .failed: .red
        case .checking, .needsPreparation, .preparing, .unsupported: .secondary
        }
    }

    private func semanticSearchStatusTitle(
        _ phase: SemanticSearchPreparationModel.Phase
    ) -> String {
        switch phase {
        case .checking: L10n.text("Checking semantic search…")
        case .needsPreparation: L10n.text("Semantic search is optional")
        case .preparing: L10n.text("Preparing semantic search…")
        case .ready: L10n.text("Semantic search is ready")
        case .unsupported: L10n.text("Semantic search isn't available")
        case .blockedByCapture: L10n.text("Finish the recording first")
        case .failed: L10n.text("Semantic search needs attention")
        }
    }

    private func semanticSearchStatusDetail(
        _ phase: SemanticSearchPreparationModel.Phase
    ) -> String {
        switch phase {
        case .checking:
            L10n.text("Checking Apple's on-device language assets. Exact search stays available.")
        case .needsPreparation:
            L10n.text(
                // One-line UI help.
                // swiftlint:disable:next line_length
                "Prepare once to add meaning-based English and Spanish matches. Preparing may use a few hundred MB on this Mac; macOS manages the assets, and exact search stays available.")
        case .preparing:
            L10n.text(
                // swiftlint:disable:next line_length
                "macOS is preparing its on-device language assets. You can close Settings; exact search stays available.")
        case .ready:
            L10n.text(
                // One-line UI help.
                // swiftlint:disable:next line_length
                "Meaning-based English and Spanish matches can augment exact search. New or corrected text is indexed in the background.")
        case .unsupported:
            L10n.text(
                // swiftlint:disable:next line_length
                "This Mac or macOS version doesn't provide the required Apple language model. Exact search still works.")
        case .blockedByCapture:
            L10n.text(
                "Preparing another on-device model could disrupt live capture. Finish the recording, then try again.")
        case .failed:
            L10n.text(
                // swiftlint:disable:next line_length
                "macOS couldn't prepare the language assets. Check your connection and storage, then try again; exact search still works.")
        }
    }
}
