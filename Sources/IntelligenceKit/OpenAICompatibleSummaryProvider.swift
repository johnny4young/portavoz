import Foundation
import PortavozCore

/// BYOK cloud and local OpenAI-compatible `/chat/completions` provider
/// (OpenAI, Anthropic gateway, Groq, OpenRouter, Ollama…).
///
/// D8 applies in full: using this is an explicit, visibly-labeled user
/// choice — never a silent default — and the API key comes from the
/// caller. Large cloud contexts run in one pass (`contextCharacterBudget == nil`);
/// bounded local endpoints (such as Ollama) supply a character budget so long
/// meetings map-reduce cleanly instead of overflowing `num_ctx`.
public struct OpenAICompatibleSummaryProvider: SummaryProvider {
    private static let maximumCondensePasses = 3

    private let client: OpenAICompatibleSummaryClient
    public let contextCharacterBudget: Int?

    public init(
        endpoint: URL,
        model: String,
        apiKey: String,
        gateway: any DataEgressGateway,
        consentSource: DataEgressConsentSource = .explicitSummaryProvider,
        requestTimeout: TimeInterval = OpenAICompatibleSummaryClient.defaultRequestTimeout,
        contextCharacterBudget: Int? = nil
    ) {
        client = OpenAICompatibleSummaryClient(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            gateway: gateway,
            consentSource: consentSource,
            requestTimeout: requestTimeout)
        self.contextCharacterBudget = contextCharacterBudget.map { max(1_000, $0) }
    }

    public func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        let material = try await preparedMaterial(for: request)
        let prompt = Self.prompt(for: request, materialText: material)
        let content = try await client.completeSummary(
            system: prompt.system,
            user: prompt.user,
            meetingID: request.meetingID)
        var draft = try Self.parseStructured(content).draft(for: request)
        draft.fingerprint = SummaryFingerprint.compute(
            request: request, providerID: "\(client.providerLabel)/\(client.model)")
        return draft
    }

    private func preparedMaterial(for request: SummaryRequest) async throws -> String {
        let transcript = TranscriptFormatter.formatWithEvidence(
            segments: request.segments, speakers: request.speakers).text
        guard let budget = contextCharacterBudget, transcript.count > budget else {
            return transcript
        }
        let mapSystem = PromptFactory.notesInstructions(
            targetLanguage: request.targetLanguage,
            glossary: request.glossary,
            detail: request.detail)
        var current = transcript
        for _ in 0..<Self.maximumCondensePasses where current.count > budget {
            let chunks = TranscriptFormatter.chunk(current, budget: budget)
            var notes: [String] = []
            notes.reserveCapacity(chunks.count)
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let raw = try await client.completeSummary(
                    system: mapSystem,
                    user: PromptFactory.notesPrompt(
                        chunk: chunk, index: index, total: chunks.count),
                    meetingID: request.meetingID)
                let visible = (ReasoningEnvelope.visibleText(raw) ?? raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !visible.isEmpty { notes.append(visible) }
            }
            let combined = notes.joined(separator: "\n\n")
            guard !combined.isEmpty, combined.count < current.count else { break }
            current = combined
        }
        // Sending it anyway would let the server truncate silently and summarize a fragment.
        guard current.count <= budget else {
            throw IntelligenceError.providerFailed(
                "the transcript is still too long for the model's context after condensing")
        }
        return current
    }

    // MARK: - Prompt/response contract (static + pure for tests)

    static func prompt(
        for request: SummaryRequest,
        materialText: String? = nil
    ) -> (system: String, user: String) {
        let material = materialText ?? TranscriptFormatter.formatWithEvidence(
            segments: request.segments, speakers: request.speakers).text
        // The user's notes weave in exactly like on-device (D28); the cloud
        // window is roomy, but the same budgets keep both paths comparable.
        let notes = PromptFactory.notesBlock(request.contextItems)
        let schemaNote = """
            Respond with ONLY a JSON object shaped exactly like:
            {"overview": "…", "overviewEvidence": ["E1"], \
            "sections": [{"heading": "…", "bullets": ["…"], \
            "bulletEvidence": [["E2"]]}], \
            "actionItems": [{"text": "…", "owner": "…", "evidence": ["E3"]}]}
            Set "overviewEvidence" to the exact E-tags that directly support the overview, \
            at most 4. Use only tags present in the material; use [] when none apply. \
            For every section, "bulletEvidence" must have exactly one array per bullet, \
            in the same order. Use up to 4 exact E-tags for bullets in the instructed \
            decision sections and [] for every other bullet. Use "" for an unknown \
            action-item owner. Every "bullets" item is a plain string — never an object \
            or key/value pair. Return one "sections" entry for every instructed recipe \
            section, in the instructed order, using empty arrays when nothing applies. \
            Action items go ONLY in "actionItems"; keep any corresponding recipe-section \
            entry empty rather than omitting it. Give each supported action item up to 4 \
            exact E-tags in "evidence", or [] when no direct source applies. \
            No markdown fences, no commentary.
            """
        return (
            system: PromptFactory.summaryInstructions(
                recipe: request.recipe,
                targetLanguage: request.targetLanguage,
                glossary: request.glossary,
                hasUserNotes: !notes.isEmpty,
                detail: request.detail) + "\n" + schemaNote,
            user: PromptFactory.summaryPrompt(
                transcriptOrNotes: material,
                targetLanguage: request.targetLanguage,
                userNotes: notes)
        )
    }

    static func parseStructured(_ content: String) throws -> StructuredSummary {
        // Reasoning drafts can hold their own braces, so the prose fallback
        // below would decode the draft instead of the answer.
        guard let answer = ReasoningEnvelope.visibleText(content) else {
            throw IntelligenceError.providerFailed(
                "the model's reasoning never finished, so it returned no summary")
        }
        // Models love fencing JSON in ```json blocks despite instructions.
        let stripped = answer
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

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
        // Keep errors content-free so raw summary text never leaks into logs or alerts.
        let decoderReason = firstDecodeError.map(Self.contentFreeReason) ?? "none"
        let ending = stripped.hasSuffix("}") ? "" : ", unterminated"
        throw IntelligenceError.providerFailed(
            "model did not return the expected JSON shape "
                + "(\(stripped.count) characters\(ending), decoder: \(decoderReason))")
    }

    /// Decoding case plus schema coding path; never the decoder's debug text,
    /// which can quote model output.
    static func contentFreeReason(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else {
            return String(describing: type(of: error))
        }
        let (name, context): (String, DecodingError.Context?) = switch decoding {
        case .keyNotFound(let key, let context): ("keyNotFound \(key.stringValue)", context)
        case .typeMismatch(_, let context): ("typeMismatch", context)
        case .valueNotFound(_, let context): ("valueNotFound", context)
        case .dataCorrupted(let context): ("dataCorrupted", context)
        @unknown default: ("DecodingError", nil)
        }
        let path = context?.codingPath
            .map { $0.intValue.map(String.init) ?? $0.stringValue }
            .joined(separator: ".") ?? ""
        return path.isEmpty ? name : "\(name) at \(path)"
    }
}
