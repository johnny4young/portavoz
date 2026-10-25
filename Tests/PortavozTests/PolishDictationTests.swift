import ApplicationKit
import IntelligenceKit
import Testing
import TranscriptionKit

struct PolishDictationTests {
    private struct Polisher: DictationTextPolishing {
        let reply: @Sendable (String) async throws -> String

        func polish(_ text: String) async throws -> String { try await reply(text) }
    }

    private struct Failure: Error {}

    private func polish(
        _ text: String, timeout: Duration = .seconds(5), terms: [String] = [],
        reply: @escaping @Sendable (String) async throws -> String
    ) async -> DictationPolishOutcome {
        await PolishDictation(polisher: Polisher(reply: reply), timeout: timeout)(text, protectedTerms: terms)
    }

    @Test
    func aFaithfulRewriteIsPasted() async {
        let outcome = await polish("so we ship it tomorrow") { _ in "  So we ship it tomorrow.\n" }
        #expect(outcome == .polished("So we ship it tomorrow."))
    }

    @Test
    func shortAndLongDictationsNeverReachTheEngine() async {
        let short = await polish("ship it") { _ in Issue.record("called"); return "" }
        #expect(short == .kept(.tooShort))
        let long = await polish(String(repeating: "word ", count: 401)) { _ in Issue.record("called"); return "" }
        #expect(long == .kept(.tooLong))
    }

    @Test
    func anUnavailableEngineKeepsItsReason() async {
        let outcome = await polish("so we ship it tomorrow") { _ in
            throw DictationPolishUnavailable(reason: "Apple Intelligence is off.")
        }
        #expect(outcome == .kept(.unavailable("Apple Intelligence is off.")))
    }

    @Test
    func failuresAndChangedFactsKeepTheCleanText() async {
        #expect(await polish("so we ship it tomorrow") { _ in throw Failure() } == .kept(.failed))
        #expect(await polish("don't ship it tomorrow") { _ in "Ship it tomorrow." }
            == .kept(.changedMeaning(.negation)))
        #expect(await polish("send it to PortaVoz now", terms: ["PortaVoz"]) { _ in "Send it to Portavoz now." }
            == .kept(.changedMeaning(.protectedTerm)))
    }

    @Test
    func aSlowEngineTimesOut() async {
        let outcome = await polish("so we ship it tomorrow", timeout: .milliseconds(50)) { text in
            try await Task.sleep(for: .seconds(30))
            return text
        }
        #expect(outcome == .kept(.timedOut))
    }
}
