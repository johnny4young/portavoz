import XCTest

@testable import PortavozCore

final class CustomRecipeTests: XCTestCase {
    func testParsesSectionsOnePerLineAndAssignsCustomID() throws {
        let recipe = try XCTUnwrap(
            Recipe.custom(
                name: "  Hangout  ",
                sectionsText: "Vibes\nWhat we caught up on\n\nPlans",
                instructions: ""))
        XCTAssertEqual(recipe.displayName, "Hangout")  // trimmed
        XCTAssertEqual(recipe.sections, ["Vibes", "What we caught up on", "Plans"])  // blank line dropped
        XCTAssertTrue(recipe.id.hasPrefix(Recipe.customIDPrefix))
        XCTAssertTrue(Recipe.isCustom(recipe.id))
    }

    func testBlankInstructionsFallBackToSafeDefault() {
        let recipe = Recipe.custom(name: "Retro", sectionsText: "Went well\nImprove", instructions: "   ")
        XCTAssertEqual(recipe?.sections.count, 2)
        XCTAssertTrue(recipe?.instructions.contains("Never invent content") ?? false)
    }

    func testCustomInstructionsArePreservedAndTrimmed() {
        let recipe = Recipe.custom(
            name: "Retro", sectionsText: "Went well", instructions: "  Keep it blameless.  ")
        XCTAssertEqual(recipe?.instructions, "Keep it blameless.")
    }

    func testEmptyNameOrSectionsReturnsNil() {
        XCTAssertNil(Recipe.custom(name: "   ", sectionsText: "Section", instructions: ""))
        XCTAssertNil(Recipe.custom(name: "Named", sectionsText: "\n  \n", instructions: ""))
    }

    func testEditingReusesTheExistingID() {
        let recipe = Recipe.custom(
            id: "custom-fixed-id", name: "Edited", sectionsText: "One\nTwo", instructions: "")
        XCTAssertEqual(recipe?.id, "custom-fixed-id")
    }

    func testBuiltInsAreNotCustom() {
        XCTAssertFalse(Recipe.isCustom(Recipe.general.id))
    }
}
