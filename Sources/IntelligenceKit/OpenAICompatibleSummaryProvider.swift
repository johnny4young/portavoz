import Foundation
import PortavozCore

/// BYOK cloud provider against any OpenAI-compatible `/chat/completions`
/// endpoint (OpenAI, Anthropic gateway, Groq, OpenRouter, Ollama…).
///
/// D8 applies in full: using this is an explicit, visibly-labeled user
/// choice — never a silent default — and the API key comes from the
/// caller (the app stores it in the Keychain; the dev CLI reads an env
/// var and says so out loud). Cloud contexts are large, so the transcript
/// goes in one pass, no map-reduce. HTTP lives in
/// `OpenAICompatibleChatClient`; this type owns only the summary prompt
/// and the JSON → `StructuredSummary` contract.
public struct OpenAICompatibleSummaryProvider: SummaryProvider {
    private let client: OpenAICompatibleChatClient

    public init(endpoint: URL, model: String, apiKey: String, session: URLSession = .shared) {
        client = OpenAICompatibleChatClient(
            endpoint: endpoint, model: model, apiKey: apiKey, session: session)
    }

    public func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        let prompt = Self.prompt(for: request)
        let content = try await client.complete(system: prompt.system, user: prompt.user)
        var draft = try Self.parseStructured(content).draft(for: request)
        draft.fingerprint = SummaryFingerprint.compute(
            request: request, providerID: "\(client.providerLabel)/\(client.model)")
        return draft
    }

    // MARK: - Prompt/response contract (static + pure for tests)

    static func prompt(for request: SummaryRequest) -> (system: String, user: String) {
        let transcript = TranscriptFormatter.format(
            segments: request.segments, speakers: request.speakers)
        // The user's notes weave in exactly like on-device (D28); the cloud
        // window is roomy, but the same budgets keep both paths comparable.
        let notes = PromptFactory.notesBlock(request.contextItems)
        let schemaNote = """
            Respond with ONLY a JSON object shaped exactly like:
            {"overview": "…", "sections": [{"heading": "…", "bullets": ["…"]}], \
            "actionItems": [{"text": "…", "owner": "…"}]}
            Use "" for an unknown action-item owner. No markdown fences, no commentary.
            """
        return (
            system: PromptFactory.summaryInstructions(
                recipe: request.recipe,
                targetLanguage: request.targetLanguage,
                glossary: request.glossary,
                hasUserNotes: !notes.isEmpty) + "\n" + schemaNote,
            user: PromptFactory.summaryPrompt(
                transcriptOrNotes: transcript,
                targetLanguage: request.targetLanguage,
                userNotes: notes)
        )
    }

    static func parseStructured(_ content: String) throws -> StructuredSummary {
        // Models love fencing JSON in ```json blocks despite instructions.
        let stripped = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let json = stripped.data(using: .utf8),
            let summary = try? JSONDecoder().decode(StructuredSummary.self, from: json)
        else {
            throw IntelligenceError.providerFailed(
                "model did not return the expected JSON shape: \(stripped.prefix(200))")
        }
        return summary
    }
}
