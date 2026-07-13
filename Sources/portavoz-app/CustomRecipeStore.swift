import Foundation
import PortavozCore

/// User-defined summary structures ("recipes"), stored as JSON in
/// UserDefaults alongside the five built-ins. A custom structure appears in
/// the meeting's "Structure" menu and shapes the summary's sections exactly
/// like a built-in — it's just a `Recipe` the user authored (name + sections
/// + optional instructions). The parsing/validation lives in
/// `Recipe.custom(…)` (PortavozCore, unit-tested); this type only persists.
enum CustomRecipeStore {
    static let key = "customRecipes"

    static func custom() -> [Recipe] {
        guard let data = UserDefaults.standard.data(forKey: key),
            let recipes = try? JSONDecoder().decode([Recipe].self, from: data)
        else { return [] }
        return recipes
    }

    static func save(_ recipes: [Recipe]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(recipes), forKey: key)
    }

    /// Built-ins first, then the user's own structures.
    static func all() -> [Recipe] { Recipe.all + custom() }

    /// Resolves an id against custom structures first, then the built-ins, so
    /// a summary generated with a custom structure still renders its name.
    static func byID(_ id: String) -> Recipe? {
        custom().first { $0.id == id } ?? Recipe.byID(id)
    }

    static func isCustom(_ id: String) -> Bool { Recipe.isCustom(id) }

    /// Adds or replaces a custom recipe (matched by id).
    static func upsert(_ recipe: Recipe) {
        var list = custom().filter { $0.id != recipe.id }
        list.append(recipe)
        save(list)
    }

    static func delete(id: String) {
        save(custom().filter { $0.id != id })
    }

    static func makeRecipe(
        id existingID: String?, name: String, sectionsText: String, instructions: String
    ) -> Recipe? {
        Recipe.custom(
            id: existingID, name: name, sectionsText: sectionsText, instructions: instructions)
    }
}
