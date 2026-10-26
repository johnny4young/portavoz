import Testing
import TranscriptionKit

struct DictationDictionaryTermsTests {
    private func rule(_ trigger: String, _ replacement: String) -> DictationReplacement {
        DictationReplacement(trigger: trigger, replacement: replacement)
    }

    @Test
    func rulesSharingASpellingAreOneTermInFirstAppearanceOrder() {
        let terms = DictationTextRules.terms([
            rule("porta voz", "Portavoz"), rule("k8s", "Kubernetes"), rule("portavós", "Portavoz")
        ])
        #expect(terms == [
            DictationTerm(replacement: "Portavoz", heard: ["porta voz", "portavós"]),
            DictationTerm(replacement: "Kubernetes", heard: ["k8s"])
        ])
    }

    @Test
    func aLearnedFormJoinsItsTermAndStillMatches() throws {
        let learned = try #require(DictationTextRules.learning(
            " portavós ", as: "Portavoz", into: [rule("porta voz", "Portavoz")]))
        #expect(DictationTextRules.terms(learned).first?.heard == ["porta voz", "portavós"])
        #expect(DictationTextRules.apply("abre portavós ya", replacements: learned, removeFillers: false)
            == "abre Portavoz ya")
    }

    @Test
    func learningAKnownFormReplacesItsOldSpelling() throws {
        let learned = try #require(DictationTextRules.learning(
            "Ana", as: "Anna", into: [rule("ana", "Ana María"), rule("k8s", "Kubernetes")]))
        #expect(learned == [rule("k8s", "Kubernetes"), rule("Ana", "Anna")])
    }

    @Test(arguments: [
        ("friday", "friday"),
        ("x", "ex"),
        ("one two three four five", "five"),
        ("friday", ""),
        ("friday", "line\nbreak"),
        ("friday", String(repeating: "a", count: 81))
    ])
    func nothingIsLearnedFromAnUnusableCorrection(_ example: (String, String)) {
        #expect(DictationTextRules.learning(example.0, as: example.1, into: []) == nil)
    }

    @Test
    func aRuleAlreadyKnownIsNotOfferedAgain() {
        #expect(DictationTextRules.learning("FRIDAY", as: "Monday", into: [rule("friday", "Monday")]) == nil)
        #expect(DictationTextRules.learning("friday", as: "Friday", into: []) != nil)
    }
}
