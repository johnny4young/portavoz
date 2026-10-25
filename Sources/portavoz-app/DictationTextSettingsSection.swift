import PortavozCore
import SwiftUI

struct DictationTextModePicker: View {
    let identifier: String
    let label: Text
    @Binding var selection: DictationTextChoice
    var recipes: [DictationRecipe] = []

    var body: some View {
        LabeledContent {
            // A Picker propagates the selected Text's identifier to its native
            // popup. Explicit menu actions keep the trigger's identity stable.
            Menu {
                Button("Literal") { selection = .init(mode: .literal) }
                    .accessibilityIdentifier(identifier + "-literal")
                Button("Clean") { selection = .init(mode: .clean) }
                    .accessibilityIdentifier(identifier + "-clean")
                Button("Polish") { selection = .init(mode: .polish) }
                    .accessibilityIdentifier(identifier + "-polish")
                if !recipes.isEmpty {
                    Divider()
                    ForEach(recipes) { recipe in
                        Button(L10n.format("Polish: %@", Self.name(of: recipe))) {
                            selection = .init(mode: .polish, recipeID: recipe.id)
                        }
                        .accessibilityIdentifier(identifier + "-recipe-" + recipe.id)
                    }
                }
            } label: {
                modeTitle
            }
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label)
            .accessibilityValue(modeTitle)
        } label: { label }
    }

    private var modeTitle: Text {
        guard selection.mode == .polish, let recipe = recipes.first(where: { $0.id == selection.recipeID })
        else { return Self.title(for: selection.mode) }
        return Text(verbatim: L10n.format("Polish: %@", Self.name(of: recipe)))
    }

    /// Built-in names are catalog keys; a custom name is the user's own text.
    static func name(of recipe: DictationRecipe) -> String {
        recipe.isBuiltIn ? L10n.text(recipe.name) : recipe.name
    }

    static func title(for mode: DictationTextMode) -> Text {
        switch mode {
        case .literal: Text("Literal")
        case .clean: Text("Clean")
        case .polish: Text("Polish")
        }
    }

}

struct DictationTextSettingsSection: View {
    let model: DictationTextSettingsModel
    let selectApplication: @MainActor () async -> Void
    @State private var showsProfiles = false

    var body: some View {
        DictationTextModePicker(
            identifier: "settings-dictation-text-mode", label: Text("Default text mode"), selection: Binding(
            get: { model.globalChoice }, set: { model.setGlobalChoice($0) }), recipes: model.recipes)
        Text(
            // One-line UI copy.
            // swiftlint:disable:next line_length
            "Literal keeps recognized words. Clean uses your filler filter and replacements. Polish starts from Clean, then your summary engine fixes grammar and punctuation on this Mac; if it would change a fact, Clean is pasted.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings-dictation-text-mode-help")
        Button {
            showsProfiles.toggle()
        } label: {
            HStack {
                Text("Application profiles")
                Spacer()
                Image(systemName: showsProfiles ? "chevron.down" : "chevron.right")
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsProfiles ? Text("Expanded") : Text("Collapsed"))
        .accessibilityIdentifier("settings-dictation-profiles")
        if showsProfiles { profiles }
        DictationRecipeSettings(model: model)
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Profiles save bundle IDs, not window titles or web addresses. A session choice takes priority.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-dictation-profile-privacy")
            if model.hasInvalidProfiles {
                Text("Application profiles could not be read. Dictation uses the default mode until you reset them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-dictation-profiles-invalid")
                Button("Reset application profiles") { model.resetProfiles() }
                    .accessibilityIdentifier("settings-dictation-profile-reset")
            } else {
                ForEach(model.profiles) { profile in
                    HStack {
                        DictationTextModePicker(
                            identifier: "settings-dictation-profile-mode-\(profile.bundleIdentifier)",
                            label: Text(verbatim: profile.bundleIdentifier), selection: Binding(
                            get: { profile.choice },
                            set: { model.setProfile(bundleIdentifier: profile.bundleIdentifier, choice: $0) }),
                            recipes: model.recipes)
                        Button("Remove") { model.removeProfile(bundleIdentifier: profile.bundleIdentifier) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.text("Remove application profile") + ": " + profile.bundleIdentifier)
                        .accessibilityIdentifier("settings-dictation-profile-remove-\(profile.bundleIdentifier)")
                    }
                }
                Button("Add application profile…") { Task { await selectApplication() } }
                    .disabled(model.isSelectingApplication
                        || model.profiles.count >= DictationTextPreferences.maximumProfiles)
                    .accessibilityIdentifier("settings-dictation-profile-add")
            }
            if let error = model.selectionError {
                selectionErrorText(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-dictation-profile-error")
            }
        }
    }

    private func selectionErrorText(_ error: DictationTextSettingsModel.SelectionError) -> Text {
        switch error {
        case .invalidApplication:
            Text("Choose an application with a valid bundle identifier. Profiles are limited to 64.")
        case .unavailableWindow:
            Text("The application chooser needs a Settings window. Open Settings and try again.")
        }
    }
}
