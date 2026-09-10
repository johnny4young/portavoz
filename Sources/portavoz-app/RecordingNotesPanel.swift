import PortavozCore
import SwiftUI

/// The coauthoring input (D28): jot notes while the meeting happens. Each note
/// is anchored to the current moment and woven into the final summary as
/// intent — expanded with facts and marked as yours (▸).
///
/// As its own tab it no longer nests a 160 pt scroll inside the assist scroll:
/// the field stays put and the notes take whatever height the tab has (D504).
struct RecordingNotesPanel: View {
    @Bindable var controller: RecordingController
    var body: some View {
        let isDraftEmpty = controller.drafts.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Add a note…", text: $controller.drafts.note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit(add)
                    .accessibilityIdentifier("recording-note-field")
                Button(action: add) {
                    Image(systemName: "arrow.up.circle.fill").imageScale(.large)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    isDraftEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .disabled(isDraftEmpty)
                .help(L10n.text("Add note (⏎)"))
                .accessibilityLabel(L10n.text("Add note (⏎)"))
                .accessibilityIdentifier("recording-note-add")
            }
            if controller.contextItems.isEmpty {
                RecordingAssistEmptyState(
                    symbol: "square.and.pencil",
                    message: L10n.text(
                        "They guide the final summary: they are expanded with facts and marked as yours (▸)."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        // Newest first — the note you just took is right there.
                        ForEach(controller.contextItems.reversed()) { item in
                            note(item)
                        }
                    }
                }
                .accessibilityIdentifier("recording-notes-list")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ item: ContextItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("▸").foregroundStyle(.tint)
            Text(ClockFormat.mmss(item.timestamp))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(item.content)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 2)
            Button {
                controller.removeContextItem(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(L10n.text("Remove note"))
            .accessibilityLabel(L10n.text("Remove note"))
            .accessibilityIdentifier("recording-note-remove-\(item.id.uuidString)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-note-\(item.id.uuidString)")
    }

    private func add() {
        let note = controller.drafts.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        controller.addContextNote(note)
        controller.drafts.note = ""
    }
}
