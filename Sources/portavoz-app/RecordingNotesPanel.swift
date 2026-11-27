import PortavozCore
import SwiftUI

/// The coauthoring input (D28): jot notes while the meeting happens. Each note
/// is anchored to the moment it is added and woven into the final summary as
/// intent — expanded with facts and marked as yours (▸).
///
/// The field sits under every assist tab, so a note never waits for a tab
/// switch; the Notes tab lists what was taken and the running summary.
struct RecordingNoteField: View {
    @Bindable var controller: RecordingController

    var body: some View {
        let isDraftEmpty = controller.drafts.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.ink3)
                .accessibilityHidden(true)
            TextField("", text: $controller.drafts.note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...3)
                .onSubmit(add)
                .accessibilityLabel(L10n.text("Add a note…"))
                .accessibilityIdentifier("recording-note-field")
                .overlay(alignment: .topLeading) {
                    if isDraftEmpty {
                        RecordingNotePlaceholder(startedAt: controller.startedAt)
                    }
                }
            if !isDraftEmpty {
                Button(action: add) {
                    Image(systemName: "arrow.up.circle.fill").imageScale(.medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PVDesign.accent)
                .help(L10n.text("Add note (⏎)"))
                .accessibilityLabel(L10n.text("Add note (⏎)"))
                .accessibilityIdentifier("recording-note-add")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(minHeight: 34)
        .background(PVDesign.card, in: RoundedRectangle(cornerRadius: PVDesign.radiusSmall, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PVDesign.radiusSmall, style: .continuous)
                .strokeBorder(PVDesign.line, lineWidth: 1)
        }
        .disabled(controller.inputPersistence.isSaving || controller.inputPersistence.hasFailure)
    }

    private func add() {
        let note = controller.drafts.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        controller.addContextNote(note)
    }
}

/// "Note at 12:04…": the moment a note would be anchored to. Its own
/// timeline, so the tick repaints the placeholder and never the field.
private struct RecordingNotePlaceholder: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(L10n.format(
                "Note at %@…",
                ClockFormat.mmss(context.date.timeIntervalSince(startedAt), truncating: true)))
                .font(.system(size: 12.5))
                .foregroundStyle(.ink3)
                .lineLimit(1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The Notes tab: your notes, newest first, then the running summary.
struct RecordingNotesPanel: View {
    @Bindable var controller: RecordingController

    var body: some View {
        if controller.contextItems.isEmpty && controller.liveSummary == nil {
            RecordingAssistEmptyState(
                symbol: "square.and.pencil",
                message: L10n.text(
                    "They guide the final summary: they are expanded with facts and marked as yours (▸)."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !controller.contextItems.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            // Newest first — the note you just took is right there.
                            ForEach(controller.contextItems.reversed()) { item in
                                note(item)
                            }
                        }
                        .accessibilityIdentifier("recording-notes-list")
                    }
                    if let markdown = controller.liveSummary {
                        VStack(alignment: .leading, spacing: 6) {
                            PVCardCaption(text: L10n.text("Summary"), tint: PVDesign.ink3)
                            MarkdownText(text: markdown)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("recording-live-summary")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func note(_ item: ContextItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("▸").foregroundStyle(PVDesign.youInk)
            Text(ClockFormat.mmss(item.timestamp))
                .font(PVFont.timeCode(.caption2))
                .foregroundStyle(.ink3)
            Text(item.content)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 2)
            Button {
                controller.removeContextItem(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.ink3)
            }
            .buttonStyle(.plain)
            .help(L10n.text("Remove note"))
            .accessibilityLabel(L10n.text("Remove note"))
            .accessibilityIdentifier("recording-note-remove-\(item.id.uuidString)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-note-\(item.id.uuidString)")
        .disabled(controller.inputPersistence.isSaving || controller.inputPersistence.hasFailure)
    }
}
