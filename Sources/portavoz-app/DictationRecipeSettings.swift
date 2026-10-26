import PortavozCore
import SwiftUI

/// Polish recipes: the four built-ins can only be duplicated; custom ones are edited here.
struct DictationRecipeSettings: View {
    let model: DictationTextSettingsModel
    @State private var showsRecipes = false
    @State private var draft: DictationRecipe?

    var body: some View {
        Button {
            showsRecipes.toggle()
        } label: {
            HStack {
                Text("Polish recipes")
                Spacer()
                Image(systemName: showsRecipes ? "chevron.down" : "chevron.right")
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsRecipes ? Text("Expanded") : Text("Collapsed"))
        .accessibilityIdentifier("settings-dictation-recipes")
        if showsRecipes { recipes }
    }

    private var recipes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A recipe tells Polish how to reshape what you dictate. It never changes facts, names or numbers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-dictation-recipes-help")
            if model.hasInvalidRecipes {
                Text("Your recipes could not be read. Polish uses the built-in ones until you reset them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-dictation-recipes-invalid")
                Button("Reset recipes") { model.resetRecipes() }
                    .accessibilityIdentifier("settings-dictation-recipe-reset")
            }
            ForEach(model.recipes) { recipe in row(recipe) }
            Button("New recipe…") {
                draft = DictationRecipe(id: UUID().uuidString, name: "", instruction: "")
            }
            .disabled(!model.canAddRecipe)
            .accessibilityIdentifier("settings-dictation-recipe-new")
        }
        .sheet(item: $draft) { recipe in
            DictationRecipeEditor(recipe: recipe) { saved in model.saveRecipe(saved) }
        }
    }

    private func row(_ recipe: DictationRecipe) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: DictationTextModePicker.name(of: recipe))
                Text(verbatim: recipe.instruction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-dictation-recipe-\(recipe.id)")
            Spacer()
            if recipe.isBuiltIn {
                Button("Duplicate") {
                    draft = DictationRecipe(
                        id: UUID().uuidString, name: DictationTextModePicker.name(of: recipe),
                        instruction: recipe.instruction)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canAddRecipe)
                .accessibilityIdentifier("settings-dictation-recipe-duplicate-\(recipe.id)")
            } else {
                Button("Edit") { draft = recipe }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings-dictation-recipe-edit-\(recipe.id)")
                Button("Delete") { model.deleteRecipe(id: recipe.id) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings-dictation-recipe-delete-\(recipe.id)")
            }
        }
    }
}

private struct DictationRecipeEditor: View {
    @Environment(\.dismiss) private var dismiss
    let save: (DictationRecipe) -> Bool
    @State private var recipe: DictationRecipe
    @State private var failed = false

    init(recipe: DictationRecipe, save: @escaping (DictationRecipe) -> Bool) {
        _recipe = State(initialValue: recipe)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Polish recipe")
                .font(.headline)
            TextField("Name", text: $recipe.name, prompt: Text("Status update"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("dictation-recipe-name")
            VStack(alignment: .leading, spacing: 4) {
                Text("How should Polish reshape your dictation?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $recipe.instruction)
                    .font(.body)
                    .frame(height: 92)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .accessibilityIdentifier("dictation-recipe-instruction")
                Text(L10n.format(
                    "%d of %d characters", recipe.instruction.count, DictationRecipe.maximumInstructionLength))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictation-recipe-instruction-count")
            }
            if failed {
                Text("This recipe could not be saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictation-recipe-error")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("dictation-recipe-cancel")
                Button("Save") {
                    if save(trimmed) { dismiss() } else { failed = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!trimmed.isValid)
                .accessibilityIdentifier("dictation-recipe-save")
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var trimmed: DictationRecipe {
        DictationRecipe(
            id: recipe.id, name: recipe.name.trimmingCharacters(in: .whitespacesAndNewlines),
            instruction: recipe.instruction.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
