import Foundation
import PortavozCore

/// BYOK cloud provider against any OpenAI-compatible `/chat/completions`
/// endpoint (OpenAI, Anthropic gateway, Groq, OpenRouter, Ollama…).
///
/// D8 applies in full: using this is an explicit, visibly-labeled user
/// choice — never a silent default — and the API key comes from the
/// caller (the app stores it in the Keychain; the dev CLI reads an env
/// var and says so out loud). Cloud contexts are large, so the transcript
/// goes in one pass, no map-reduce. Transport crosses `DataEgressGateway`;
/// this type owns the summary prompt and JSON → `StructuredSummary` contract.
public struct OpenAICompatibleSummaryProvider: SummaryProvider {
    private let client: OpenAICompatibleSummaryClient

    public init(
        endpoint: URL,
        model: String,
        apiKey: String,
        gateway: any DataEgressGateway,
        consentSource: DataEgressConsentSource = .explicitSummaryProvider
    ) {
        client = OpenAICompatibleSummaryClient(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            gateway: gateway,
            consentSource: consentSource)
    }

    public func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        let prompt = Self.prompt(for: request)
        let content = try await client.completeSummary(
            system: prompt.system,
            user: prompt.user,
            meetingID: request.meetingID)
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
            Use "" for an unknown action-item owner. Every "bullets" item is a plain \
            string — never an object or key/value pair. Action items go ONLY in \
            "actionItems"; never add an action-items section to "sections". \
            No markdown fences, no commentary.
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

        // Local debugging only: dump the raw output when explicitly asked.
        if ProcessInfo.processInfo.environment["PORTAVOZ_JSON_DUMP"] != nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("portavoz-summary-dump.txt")
            try? stripped.write(to: url, atomically: true, encoding: .utf8)
        }
        var firstDecodeError: Error?
        var candidates = [stripped]
        // Smaller local models also wrap the object in prose ("Here is the
        // summary: {…} Let me know…") — add the outermost-braces slice.
        if let first = stripped.firstIndex(of: "{"), let last = stripped.lastIndex(of: "}"),
            first < last {
            candidates.append(String(stripped[first...last]))
        }
        for candidate in candidates {
            // Qwen3-4B (MLX) emits Python-style \' escapes inside strings —
            // invalid JSON that fails the whole document. Repairing them is
            // safe: \' never appears in valid JSON.
            for text in [candidate, candidate.replacingOccurrences(of: "\\'", with: "'")] {
                guard let json = text.data(using: .utf8) else { continue }
                do {
                    return try JSONDecoder().decode(StructuredSummary.self, from: json)
                } catch {
                    if firstDecodeError == nil { firstDecodeError = error }
                }
            }
        }
        // Head AND tail: a truncated generation is instantly visible from
        // an unterminated tail, while a refusal shows in the head.
        throw IntelligenceError.providerFailed(
            "model did not return the expected JSON shape "
                + "(\(stripped.count) characters): \(stripped.prefix(160)) … \(stripped.suffix(160)) "
                + "— decoder: \(firstDecodeError.map(String.init(describing:)) ?? "none")")
    }
}
