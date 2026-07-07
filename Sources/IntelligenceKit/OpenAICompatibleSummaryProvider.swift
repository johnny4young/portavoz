import Foundation
import PortavozCore

/// BYOK cloud provider against any OpenAI-compatible `/chat/completions`
/// endpoint (OpenAI, Anthropic gateway, Groq, OpenRouter, Ollama…).
///
/// D8 applies in full: using this is an explicit, visibly-labeled user
/// choice — never a silent default — and the API key comes from the
/// caller (the app stores it in the Keychain; the dev CLI reads an env
/// var and says so out loud). Cloud contexts are large, so the transcript
/// goes in one pass, no map-reduce.
public struct OpenAICompatibleSummaryProvider: SummaryProvider {
    public let endpoint: URL
    public let model: String
    private let apiKey: String
    private let session: URLSession

    public init(endpoint: URL, model: String, apiKey: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    public func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        let urlRequest = try Self.urlRequest(
            for: request, endpoint: endpoint, model: model, apiKey: apiKey)
        let (data, response) = try await session.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw IntelligenceError.providerFailed("HTTP \(status): \(body)")
        }

        let structured = try Self.parseResponse(data)
        return structured.draft(for: request)
    }

    // MARK: - Request/response shapes (static + pure for tests)

    static func urlRequest(
        for request: SummaryRequest, endpoint: URL, model: String, apiKey: String
    ) throws -> URLRequest {
        let transcript = TranscriptFormatter.format(
            segments: request.segments, speakers: request.speakers)
        let schemaNote = """
            Respond with ONLY a JSON object shaped exactly like:
            {"overview": "…", "sections": [{"heading": "…", "bullets": ["…"]}], \
            "actionItems": [{"text": "…", "owner": "…"}]}
            Use "" for an unknown action-item owner. No markdown fences, no commentary.
            """
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                [
                    "role": "system",
                    "content": PromptFactory.summaryInstructions(
                        recipe: request.recipe,
                        targetLanguage: request.targetLanguage,
                        glossary: request.glossary) + "\n" + schemaNote,
                ],
                [
                    "role": "user",
                    "content": PromptFactory.summaryPrompt(
                        transcriptOrNotes: transcript, targetLanguage: request.targetLanguage),
                ],
            ],
        ]

        var urlRequest = URLRequest(url: endpoint.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func parseResponse(_ data: Data) throws -> StructuredSummary {
        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let content = try? JSONDecoder().decode(ChatResponse.self, from: data)
            .choices.first?.message.content
        else {
            throw IntelligenceError.providerFailed("response is not a chat completion")
        }

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
