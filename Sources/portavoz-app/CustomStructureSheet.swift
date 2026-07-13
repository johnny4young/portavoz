import PortavozCore
import SwiftUI

/// Create or edit a custom summary structure: a name, the sections (one per
/// line), and optional shaping instructions. Saving hands back the `Recipe`.
struct CustomStructureSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The structure being edited, or nil for a brand-new one.
    let existing: Recipe?
    let onSave: (Recipe) -> Void

    @State private var name: String
    @State private var sectionsText: String
    @State private var instructions: String

    init(existing: Recipe?, onSave: @escaping (Recipe) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.displayName ?? "")
        _sectionsText = State(
            initialValue: (existing?.sections ?? ["Overview", "Highlights", "Next Steps"])
                .joined(separator: "\n"))
        _instructions = State(initialValue: existing?.instructions ?? "")
    }

    private var canSave: Bool {
        CustomRecipeStore.makeRecipe(
            id: existing?.id, name: name, sectionsText: sectionsText, instructions: instructions
        ) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "New structure" : "Edit structure")
                .font(.headline)

            TextField("Name", text: $name, prompt: Text("Hangout"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("structure-name")

            VStack(alignment: .leading, spacing: 4) {
                Text("Sections — one per line").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $sectionsText)
                    .font(.body.monospaced())
                    .frame(height: 92)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.quaternary))
                    .accessibilityIdentifier("structure-sections")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Extra instructions (optional)").font(.caption).foregroundStyle(.secondary)
                TextField(
                    "How this summary should be shaped…", text: $instructions, axis: .vertical
                )
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        guard let recipe = CustomRecipeStore.makeRecipe(
            id: existing?.id, name: name, sectionsText: sectionsText, instructions: instructions)
        else { return }
        onSave(recipe)
        dismiss()
    }
}
