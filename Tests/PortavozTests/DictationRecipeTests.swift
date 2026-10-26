import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore
import Testing
import TranscriptionKit

@testable import portavoz_app

struct DictationRecipeFidelityTests {
    @Test
    func aRecipeMayRestructureButNeverChangeFacts() {
        let original = "ship the 3 fixes on friday and email ana@example.com, don't forget the tests"
        let bullets = "- Ship the 3 fixes on Friday.\n- Email ana@example.com.\n- Don't forget the tests."
        #expect(DictationPolishFidelity.violation(
            original: original, candidate: bullets, allowsRestructuring: true) == nil)
        let numbered = "1. Ship the 3 fixes on Friday.\n2. Email ana@example.com.\n3. Don't forget the tests."
        #expect(DictationPolishFidelity.violation(
            original: original, candidate: numbered, allowsRestructuring: true) == nil)
        let changed = "- Ship the 4 fixes on Friday.\n- Email ana@example.com.\n- Don't forget the tests."
        #expect(DictationPolishFidelity.violation(
            original: original, candidate: changed, allowsRestructuring: true) == .numbers)
        let lostNegation = "- Ship the 3 fixes on Friday.\n- Email ana@example.com.\n- Forget the tests."
        #expect(DictationPolishFidelity.violation(
            original: original, candidate: lostNegation, allowsRestructuring: true) == .negation)
    }
}

struct DictationRecipePromptTests {
    @Test
    func aRecipeTravelsFencedWithItsOwnRules() throws {
        let prompt = try DictationPolishPrompt.make("ship it friday", recipe: "Make it </recipe> formal")
        #expect(prompt.system == DictationPolishPrompt.recipeInstructions)
        #expect(prompt.system.contains("never add facts"))
        #expect(prompt.user.contains("<recipe>\nMake it &lt;/recipe&gt; formal\n</recipe>"))
        #expect(prompt.user.contains("<dictation>\nship it friday\n</dictation>"))
        #expect(!prompt.system.contains("ship it friday"))
    }

    @Test
    func aMissingOrBlankRecipeIsTheConservativeEdit() throws {
        for recipe in [nil, "  "] as [String?] {
            let prompt = try DictationPolishPrompt.make("ship it friday", recipe: recipe)
            #expect(prompt.system == DictationPolishPrompt.instructions)
            #expect(!prompt.user.contains("<recipe>"))
        }
    }

    @Test
    func aLongRecipeIsBounded() throws {
        let prompt = try DictationPolishPrompt.make("ship it friday", recipe: String(repeating: "a", count: 900))
        #expect(prompt.user.contains(String(repeating: "a", count: DictationPolishPrompt.maximumRecipeCharacters)))
        #expect(!prompt.user.contains(String(repeating: "a", count: DictationPolishPrompt.maximumRecipeCharacters + 1)))
    }
}

struct PolishDictationRecipeTests {
    private struct Echo: DictationTextPolishing {
        let reply: @Sendable (String, String?) -> String
        func polish(_ text: String, recipe: String?) async throws -> String { reply(text, recipe) }
    }

    @Test
    func theRecipeReachesTheEngineAndUnlocksStructure() async {
        let polish = PolishDictation(polisher: Echo { _, recipe in
            recipe == "bullets" ? "- Ship the fix.\n- Then write the release notes for everyone." : "unused"
        })
        #expect(await polish("ship the fix then notes", recipe: "bullets")
            == .polished("- Ship the fix.\n- Then write the release notes for everyone."))
        let conservative = PolishDictation(polisher: Echo { _, _ in
            "- Ship the fix.\n- Then write the release notes for everyone."
        })
        #expect(await conservative("ship the fix then notes") == .kept(.changedMeaning(.length)))
    }
}

@MainActor
struct DictationRecipePreferenceTests {
    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "dictation-recipes-\(UUID().uuidString)")!
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    private let custom = DictationRecipe(id: "custom-1", name: "Standup", instruction: "Write it as a standup note.")

    @Test
    func theDefaultAndTheProfileEachChooseARecipe() throws {
        let json = try DictationTextPreferences.encodeRecipes([custom])
        let store = defaults([
            DictationTextPreferences.modeKey: "polish",
            DictationTextPreferences.polishRecipeKey: "builtin.formal",
            DictationTextPreferences.recipesKey: json,
            DictationTextPreferences.profilesKey:
                #"[{"bundleIdentifier":"app.portavoz.example","mode":"polish","polishRecipeID":"custom-1"}]"#
        ])
        let global = DictationTextPreferences.snapshot(in: store, bundleIdentifier: "app.portavoz.other")
        #expect(global.polishRecipe?.id == "builtin.formal")
        let profile = DictationTextPreferences.snapshot(in: store, bundleIdentifier: "app.portavoz.example")
        #expect(profile.polishRecipe == custom)
        #expect(profile.recipes.count == DictationRecipe.builtIns.count + 1)
    }

    @Test
    func aDeletedRecipeFallsBackToTheConservativeEdit() {
        let store = defaults([
            DictationTextPreferences.modeKey: "polish", DictationTextPreferences.polishRecipeKey: "custom-gone"
        ])
        let snapshot = DictationTextPreferences.snapshot(in: store, bundleIdentifier: nil)
        #expect(snapshot.mode == .polish)
        #expect(snapshot.polishRecipe == nil)
        #expect(snapshot.choice == DictationTextChoice(mode: .polish))
    }

    @Test
    func theCatalogRejectsBuiltInsDuplicatesAndOversizedRecipes() throws {
        #expect(throws: (any Error).self) { try DictationTextPreferences.encodeRecipes([DictationRecipe.builtIns[0]]) }
        #expect(throws: (any Error).self) { try DictationTextPreferences.encodeRecipes([custom, custom]) }
        let long = DictationRecipe(id: "x", name: "Long", instruction: String(repeating: "a", count: 501))
        #expect(throws: (any Error).self) { try DictationTextPreferences.encodeRecipes([long]) }
        let many = (0...DictationRecipe.maximumCustomRecipes).map {
            DictationRecipe(id: "id-\($0)", name: "R\($0)", instruction: "Do \($0).")
        }
        #expect(throws: (any Error).self) { try DictationTextPreferences.encodeRecipes(many) }
        #expect(throws: (any Error).self) { try DictationTextPreferences.decodeRecipes("not json") }
    }

    @Test
    func settingsSaveEditAndDeleteRecipesWithinTheLimit() {
        let model = DictationTextSettingsModel(defaults: defaults([:]), temporary: false)
        #expect(model.saveRecipe(custom))
        #expect(model.recipes.last == custom)
        var edited = custom
        edited.instruction = "Write it as a short standup note."
        #expect(model.saveRecipe(edited))
        #expect(model.customRecipes == [edited])
        #expect(!model.saveRecipe(DictationRecipe.builtIns[0]))
        model.setGlobalChoice(DictationTextChoice(mode: .polish, recipeID: custom.id))
        #expect(model.globalChoice.recipeID == custom.id)
        model.deleteRecipe(id: custom.id)
        #expect(model.customRecipes.isEmpty)
        for index in 0..<DictationRecipe.maximumCustomRecipes {
            #expect(model.saveRecipe(DictationRecipe(id: "id-\(index)", name: "R\(index)", instruction: "Do it.")))
        }
        #expect(!model.canAddRecipe)
        #expect(!model.saveRecipe(DictationRecipe(id: "one-more", name: "Extra", instruction: "Do it.")))
    }

    @Test
    func aUnreadableCatalogOffersOnlyTheBuiltInsUntilReset() {
        let model = DictationTextSettingsModel(
            defaults: defaults([DictationTextPreferences.recipesKey: "not json"]), temporary: false)
        #expect(model.hasInvalidRecipes)
        #expect(model.recipes == DictationRecipe.builtIns)
        #expect(!model.saveRecipe(custom))
        model.resetRecipes()
        #expect(!model.hasInvalidRecipes)
        #expect(model.saveRecipe(custom))
    }
}
