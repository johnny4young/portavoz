import Testing
import TranscriptionKit

struct DictationPolishFidelityTests {
    struct Case: Sendable, CustomStringConvertible {
        let original: String
        let candidate: String
        var terms: [String] = []
        let expected: DictationPolishFidelity.Violation?
        var description: String { candidate }
    }

    static let cases: [Case] = [
        Case(original: "so i think we should ship it tomorrow", candidate: "So I think we should ship it tomorrow.",
             expected: nil),
        Case(original: "creo que deberíamos lanzarlo mañana", candidate: "Creo que deberíamos lanzarlo mañana.",
             expected: nil),
        Case(original: "the budget is 1,000 dollars", candidate: "The budget is 1000 dollars.", expected: nil),
        Case(original: "meet at 3 with 12 people", candidate: "Meet at 3 with twelve people.", expected: .numbers),
        Case(original: "meet at three", candidate: "Meet at 3.", expected: .numbers),
        Case(original: "write to ana@example.com today", candidate: "Write to Ana@example.com today.",
             expected: .identifiers),
        Case(original: "open https://portavoz.app/docs now", candidate: "Open https://portavoz.app now.",
             expected: .identifiers),
        Case(original: "ping @maria about #release", candidate: "Ping Maria about the release.",
             expected: .identifiers),
        Case(original: "send it to PortaVoz support", candidate: "Send it to Portavoz support.",
             terms: ["PortaVoz"], expected: .protectedTerm),
        Case(original: "don't delete these notes", candidate: "Delete these notes.", expected: .negation),
        Case(original: "do not delete these notes", candidate: "Don't delete these notes.", expected: nil),
        Case(original: "no borres estas notas", candidate: "Borra estas notas.", expected: .negation),
        Case(original: "ship it today", candidate: "Don't ship it today.", expected: .negation),
        Case(original: "nunca lo envíes sin revisar", candidate: "Nunca lo envíes sin revisarlo.", expected: nil),
        Case(original: "we need to review the plan and then send the final version to the whole team",
             candidate: "Review the plan.", expected: .length),
        Case(original: "please send the updated plan to the whole team",
             candidate: "Sure, please send the updated plan to the team.", expected: .preamble),
        Case(original: "please send the quarterly plan to the whole team before the meeting",
             candidate: "Por favor envía el plan trimestral a todo el equipo antes de la reunión.",
             expected: .language),
        Case(original: "let's review el presupuesto con el equipo and then ship it",
             candidate: "Let's review el presupuesto con el equipo, and then ship it.", expected: nil),
        Case(original: "anything", candidate: "  ", expected: .empty)
    ]

    @Test(arguments: cases)
    func rewritesKeepFactsAndOnlyChangeForm(_ example: Case) {
        #expect(DictationPolishFidelity.violation(
            original: example.original, candidate: example.candidate, protectedTerms: example.terms)
            == example.expected)
    }

    @Test
    func protectedTermsOnlyBindWhenTheUserSaidThem() {
        #expect(DictationPolishFidelity.violation(
            original: "send it to support", candidate: "Send it to support.", protectedTerms: ["PortaVoz"]) == nil)
    }
}
