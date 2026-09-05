import ApplicationKit
import Foundation
import PortavozCore
import SwiftUI

private enum TranscriptStructuralDraft: Equatable {
    case split
    case merge(TranscriptMergeCandidate)
    case suppress
}

struct TranscriptStructuralCorrectionControls: View {
    let context: TranscriptStructuralCorrectionContext
    let perform: (TranscriptStructuralCorrectionOperation) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: TranscriptStructuralDraft?
    @State private var firstText: String
    @State private var secondText: String
    @State private var splitTime: TimeInterval
    @State private var isSaving = false
    @State private var operationError: String?

    init(
        context: TranscriptStructuralCorrectionContext,
        perform: @escaping (TranscriptStructuralCorrectionOperation) async -> String?
    ) {
        self.context = context
        self.perform = perform
        let source = context.originals.first
        let parts = Self.defaultSplit(source?.text ?? "")
        _firstText = State(initialValue: parts.0)
        _secondText = State(initialValue: parts.1)
        _splitTime = State(initialValue: source.map {
            $0.startTime + ($0.endTime - $0.startTime) / 2
        } ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Line structure", systemImage: "rectangle.split.2x1")
                .font(.headline)
            if let active = context.activeCorrection {
                activeCorrection(active)
            } else if context.hasIncompatibleCorrection {
                Label(
                    "Undo the text or speaker correction before changing this line's structure.",
                    systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transcript-structure-guidance")
            } else if let draft {
                draftEditor(draft)
            } else {
                availableActions
            }
            if let operationError {
                Label(operationError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("transcript-structure-error")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript-structure-controls")
    }

    @ViewBuilder
    private func activeCorrection(_ event: TranscriptCorrectionEvent) -> some View {
        Label(activeLabel(event), systemImage: activeIcon(event))
            .font(.callout)
            .foregroundStyle(.secondary)
        originalRows
        Button("Undo structural correction", role: .destructive) {
            run(.restore(correctionID: event.id))
        }
        .disabled(isSaving)
        .accessibilityIdentifier("transcript-structure-undo")
        .help("Restore the exact accepted transcript lines without deleting history")
    }

    private var availableActions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Change how this line is grouped while keeping the recording evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if context.canSplit {
                    Button("Split line…") { draft = .split }
                        .accessibilityIdentifier("transcript-structure-split")
                }
                if context.canSuppress {
                    Button("Hide as noise…", role: .destructive) { draft = .suppress }
                        .accessibilityIdentifier("transcript-structure-suppress")
                }
            }
            ForEach(context.mergeCandidates) { candidate in
                Button {
                    draft = .merge(candidate)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.direction == .previous
                            ? "Merge with previous line…"
                            : "Merge with next line…")
                        Text(neighborText(candidate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("transcript-structure-merge-\(candidate.id.uuidString)")
            }
        }
    }

    @ViewBuilder
    private func draftEditor(_ draft: TranscriptStructuralDraft) -> some View {
        switch draft {
        case .split:
            splitEditor
        case .merge(let candidate):
            confirmation(
                title: "Merge these two lines?",
                explanation: "They will appear as one line and keep links to both originals.",
                rows: candidate.rows,
                confirmTitle: "Merge lines",
                operation: .merge(sourceSegmentIDs: candidate.rows.map(\.id)))
        case .suppress:
            confirmation(
                title: "Hide this line as noise?",
                explanation: "It leaves the transcript view, but the original and a restore action remain available.",
                rows: context.originals,
                confirmTitle: "Hide line",
                operation: .suppress(sourceSegmentID: context.originals[0].id))
        }
    }

    private var splitEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Split into two lines").font(.headline)
            TextField("First line", text: $firstText, axis: .vertical)
                .lineLimit(2 ... 4)
                .accessibilityIdentifier("transcript-structure-split-first")
            TextField("Second line", text: $secondText, axis: .vertical)
                .lineLimit(2 ... 4)
                .accessibilityIdentifier("transcript-structure-split-second")
            if let source = context.originals.first {
                Slider(
                    value: $splitTime,
                    in: splitRange(source),
                    step: 0.05)
                    .accessibilityLabel("Split time")
                    .accessibilityValue(clock(splitTime))
                    .accessibilityIdentifier("transcript-structure-split-time")
                Text(L10n.format("Boundary at %@", clock(splitTime)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            confirmationActions(
                confirmTitle: "Split line",
                disabled: !canSubmitSplit,
                operation: context.originals.first.map {
                    .split(
                        sourceSegmentID: $0.id,
                        firstText: firstText,
                        secondText: secondText,
                        splitTime: splitTime)
                })
        }
    }

    private func confirmation(
        title: LocalizedStringKey,
        explanation: LocalizedStringKey,
        rows: [MeetingTranscriptContent.Row],
        confirmTitle: LocalizedStringKey,
        operation: TranscriptStructuralCorrectionOperation
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            Text(explanation).font(.caption).foregroundStyle(.secondary)
            ForEach(rows) { row in
                Text(row.text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            confirmationActions(
                confirmTitle: confirmTitle,
                disabled: false,
                operation: operation)
        }
    }

    private func confirmationActions(
        confirmTitle: LocalizedStringKey,
        disabled: Bool,
        operation: TranscriptStructuralCorrectionOperation?
    ) -> some View {
        HStack {
            Button("Back") { draft = nil }
                .disabled(isSaving)
                .accessibilityIdentifier("transcript-structure-cancel")
            Spacer()
            if isSaving { ProgressView().controlSize(.small) }
            Button(confirmTitle) {
                if let operation { run(operation) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(disabled || isSaving || operation == nil)
            .accessibilityIdentifier("transcript-structure-confirm")
        }
    }

    private var originalRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(context.originals) { row in
                Text(row.text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript-structure-original-evidence")
    }

    private func run(_ operation: TranscriptStructuralCorrectionOperation) {
        guard !isSaving else { return }
        isSaving = true
        operationError = nil
        Task { @MainActor in
            if let error = await perform(operation) {
                operationError = error
                isSaving = false
            } else {
                dismiss()
            }
        }
    }

    private var canSubmitSplit: Bool {
        TranscriptContentPolicy.hasLexicalContent(firstText)
            && TranscriptContentPolicy.hasLexicalContent(secondText)
    }

    private func splitRange(
        _ source: MeetingTranscriptContent.Row
    ) -> ClosedRange<TimeInterval> {
        let epsilon = min(0.05, (source.endTime - source.startTime) / 4)
        return (source.startTime + epsilon) ... (source.endTime - epsilon)
    }

    private func neighborText(_ candidate: TranscriptMergeCandidate) -> String {
        switch candidate.direction {
        case .previous: candidate.rows.first?.text ?? ""
        case .next: candidate.rows.last?.text ?? ""
        }
    }

    private func activeLabel(_ event: TranscriptCorrectionEvent) -> LocalizedStringKey {
        switch event.kind {
        case .split: "This line was split."
        case .merge: "These lines were merged."
        case .suppress: "This line is hidden as noise."
        case .replaceText, .changeSpeaker, .restore: "This line has a correction."
        }
    }

    private func activeIcon(_ event: TranscriptCorrectionEvent) -> String {
        switch event.kind {
        case .split: "rectangle.split.2x1"
        case .merge: "rectangle.compress.vertical"
        case .suppress: "eye.slash"
        case .replaceText, .changeSpeaker, .restore: "pencil"
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func defaultSplit(_ text: String) -> (String, String) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return (text, "") }
        let midpoint = max(1, words.count / 2)
        return (
            words[..<midpoint].joined(separator: " "),
            words[midpoint...].joined(separator: " "))
    }
}

struct TranscriptStructuralCorrectionEditor: View {
    let context: TranscriptStructuralCorrectionContext
    let perform: (TranscriptStructuralCorrectionOperation) async -> String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review transcript structure")
                .font(.title2.bold())
            Text("The accepted recording and transcript lines remain unchanged.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TranscriptStructuralCorrectionControls(
                context: context,
                perform: perform)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("transcript-structure-close")
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420, idealHeight: 540)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript-structure-editor")
    }
}

struct SuppressedTranscriptCorrectionsSheet: View {
    let contexts: [TranscriptStructuralCorrectionContext]
    let restore: (TranscriptStructuralCorrectionOperation) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var restoringID: UUID?
    @State private var operationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hidden transcript lines")
                .font(.title2.bold())
            Text("Noise stays out of the reading without deleting recorded evidence.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(contexts) { context in
                        hiddenRow(context)
                    }
                }
            }
            if let operationError {
                Text(operationError).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 360, idealHeight: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript-hidden-lines-sheet")
    }

    private func hiddenRow(
        _ context: TranscriptStructuralCorrectionContext
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(context.originals.map(\.text).joined(separator: " "))
                    .textSelection(.enabled)
                Text("Hidden as noise · original preserved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if restoringID == context.id {
                ProgressView().controlSize(.small)
            }
            Button("Restore") {
                guard let correctionID = context.activeCorrection?.id else { return }
                restoringID = context.id
                operationError = nil
                Task { @MainActor in
                    if let error = await restore(.restore(correctionID: correctionID)) {
                        operationError = error
                        restoringID = nil
                    } else {
                        dismiss()
                    }
                }
            }
            .disabled(restoringID != nil)
            .accessibilityIdentifier("transcript-hidden-restore-\(context.id.uuidString)")
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
    }
}
