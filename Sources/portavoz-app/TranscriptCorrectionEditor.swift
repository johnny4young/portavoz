import ApplicationKit
import PortavozCore
import SwiftUI

struct TranscriptCorrectionEditor: View {
    let context: TranscriptCorrectionEditorContext
    let speakers: [Speaker]
    let save: (String, SpeakerID?) async -> String?
    let undo: () async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var speakerID: SpeakerID?
    @State private var isSaving = false
    @State private var operationError: String?
    @FocusState private var textEditorFocused: Bool

    init(
        context: TranscriptCorrectionEditorContext,
        speakers: [Speaker],
        save: @escaping (String, SpeakerID?) async -> String?,
        undo: @escaping () async -> String?
    ) {
        self.context = context
        self.speakers = speakers
        self.save = save
        self.undo = undo
        _text = State(initialValue: context.current.text)
        _speakerID = State(initialValue: context.current.speakerID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if context.hasStructuralCorrection {
                Label(
                    // swiftlint:disable:next line_length
                    "This row already has a split, merge, or suppression correction. Text and speaker editing is unavailable.",
                    systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transcript-correction-mode-guidance")
            }
            textEditor
            speakerPicker
            originalEvidence
            history
            if let operationError {
                Label(operationError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("transcript-correction-error")
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 540, idealHeight: 640)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript-correction-editor")
        .onAppear { textEditorFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Correct transcript")
                .font(.title2.bold())
            Text(
                // swiftlint:disable:next line_length
                "The original remains available as evidence. Existing summaries and search results are not regenerated.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Text").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .focused($textEditorFocused)
                .frame(minHeight: 110)
                .padding(8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Corrected transcript text")
                .accessibilityIdentifier("transcript-correction-text")
                .disabled(context.hasStructuralCorrection || isSaving)
        }
    }

    private var speakerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speaker").font(.headline)
            Picker("Correct speaker", selection: $speakerID) {
                Text("Unknown speaker").tag(Optional<SpeakerID>.none)
                ForEach(speakers) { speaker in
                    Text(speaker.displayName ?? speaker.label)
                        .tag(Optional(speaker.id))
                }
            }
            .accessibilityIdentifier("transcript-correction-speaker")
            .disabled(context.hasStructuralCorrection || isSaving)
        }
    }

    private var originalEvidence: some View {
        DisclosureGroup("Original evidence") {
            VStack(alignment: .leading, spacing: 3) {
                Text(speakerName(context.original.speakerID))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(context.original.text)
                    .textSelection(.enabled)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("transcript-correction-original-evidence")
    }

    @ViewBuilder
    private var history: some View {
        if !context.history.isEmpty {
            DisclosureGroup("Correction history") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(context.history) { event in
                        Label(historyLabel(event), systemImage: historyIcon(event))
                            .font(.caption)
                    }
                }
                .padding(.top, 8)
            }
            .accessibilityIdentifier("transcript-correction-history")
        }
    }

    private var actions: some View {
        HStack {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Saving transcript correction")
                    .accessibilityIdentifier("transcript-correction-progress")
            }
            if context.hasTextCorrection || context.hasSpeakerCorrection {
                Button("Undo correction", role: .destructive) {
                    perform { await undo() }
                }
                .disabled(isSaving)
                .accessibilityIdentifier("transcript-correction-undo")
                .help("Restore the original text and speaker with durable history entries")
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                .accessibilityIdentifier("transcript-correction-cancel")
            Button("Save correction") {
                perform { await save(submittedText, speakerID) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave || isSaving)
            .accessibilityIdentifier("transcript-correction-save")
        }
    }

    private func perform(_ operation: @escaping () async -> String?) {
        guard !isSaving else { return }
        isSaving = true
        operationError = nil
        Task { @MainActor in
            let error = await operation()
            isSaving = false
            if let error {
                operationError = error
            } else {
                dismiss()
            }
        }
    }

    private var canSave: Bool {
        !context.hasStructuralCorrection
            && TranscriptContentPolicy.hasLexicalContent(submittedText)
            && (submittedText != context.current.text
                || speakerID != context.current.speakerID)
    }

    /// Speaker-only edits must preserve the current transcript evidence
    /// exactly. Text the user actually changes is normalized at the UI
    /// boundary before the application command validates it again.
    private var submittedText: String {
        text == context.current.text
            ? context.current.text
            : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func speakerName(_ id: SpeakerID?) -> String {
        guard let id,
              let speaker = speakers.first(where: { $0.id == id })
        else { return L10n.text("Unknown speaker") }
        return speaker.displayName ?? speaker.label
    }

    private func historyLabel(_ event: TranscriptCorrectionEvent) -> String {
        switch event.kind {
        case .replaceText: L10n.text("Text corrected")
        case .changeSpeaker: L10n.text("Speaker corrected")
        case .split: L10n.text("Segment split")
        case .merge: L10n.text("Segments merged")
        case .suppress: L10n.text("Segment hidden")
        case .restore: L10n.text("Original restored")
        }
    }

    private func historyIcon(_ event: TranscriptCorrectionEvent) -> String {
        if event.deletedAt != nil { return "trash" }
        if case .restore = event.kind { return "arrow.uturn.backward" }
        return "pencil"
    }
}
