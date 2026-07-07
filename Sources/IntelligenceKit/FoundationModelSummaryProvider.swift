import Foundation
import PortavozCore

public enum IntelligenceError: Error, LocalizedError {
    /// Apple Intelligence is off, still downloading, or the device can't run it.
    case modelUnavailable(String)
    case providerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            return "on-device model unavailable: \(reason)"
        case .providerFailed(let reason):
            return "summary provider failed: \(reason)"
        }
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// The default, on-device summary provider: Apple Foundation Models
/// (macOS 26+, Apple Intelligence). Nothing leaves the device (D8).
///
/// The on-device model has a 4096-token context *including* output, so
/// meetings are summarized incrementally: transcript chunks → dense notes
/// (map), notes → structured summary via guided generation (reduce);
/// note layers collapse recursively until they fit one window.
@available(macOS 26.0, iOS 26.0, *)
public struct FoundationModelSummaryProvider: SummaryProvider {
    public init() {}

    /// nil when ready; otherwise a human-readable reason (Apple
    /// Intelligence off, model still downloading, unsupported device).
    public static func unavailabilityReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "this device does not support Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off (System Settings → Apple Intelligence & Siri)"
            case .modelNotReady:
                return "the on-device model is still downloading; try again in a few minutes"
            @unknown default:
                return "unknown reason"
            }
        }
    }

    /// Protocol witness (`SummaryProvider`): a defaulted parameter doesn't
    /// satisfy the requirement, so the plain overload forwards.
    public func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        try await summarize(request, priority: .interactive)
    }

    public func summarize(
        _ request: SummaryRequest,
        priority: IntelligenceScheduler.Priority
    ) async throws -> SummaryDraft {
        let transcript = TranscriptFormatter.format(
            segments: request.segments, speakers: request.speakers)
        return try await summarizeMaterial(transcript, request: request, priority: priority)
    }

    /// Reduce phase over already-condensed notes (the live rolling summary
    /// accumulates them window by window and re-renders from here).
    public func summarizeNotes(
        _ notes: String,
        request: SummaryRequest,
        priority: IntelligenceScheduler.Priority = .interactive
    ) async throws -> SummaryDraft {
        try await summarizeMaterial(notes, request: request, priority: priority)
    }

    /// One map-phase pass: condenses a transcript window into dense notes
    /// (≤250 tokens per chunk). The live summary calls this once per tick
    /// with only the NEW segments, keeping per-tick cost flat no matter how
    /// long the meeting gets.
    public func condenseWindow(
        segments: [TranscriptSegment],
        speakers: [Speaker],
        targetLanguage: String,
        glossary: [String] = [],
        priority: IntelligenceScheduler.Priority = .interactive
    ) async throws -> String {
        if let reason = Self.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }
        let transcript = TranscriptFormatter.format(segments: segments, speakers: speakers)
        let chunks = TranscriptFormatter.chunk(
            transcript, budget: TranscriptFormatter.onDeviceChunkBudget)
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let session = LanguageModelSession(
                instructions: PromptFactory.notesInstructions(
                    targetLanguage: targetLanguage, glossary: glossary))
            let note = try await IntelligenceScheduler.shared.run(priority) {
                try await session.respond(
                    to: PromptFactory.notesPrompt(
                        chunk: chunk, index: index, total: chunks.count),
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 250)
                ).content
            }
            notes.append(note)
        }
        return notes.joined(separator: "\n")
    }

    /// Collapses an oversized pile of accumulated notes back under the
    /// reduce budget (the live summary calls this occasionally so its notes
    /// never grow unbounded).
    public func condenseNotes(
        _ notes: String,
        targetLanguage: String,
        glossary: [String] = [],
        priority: IntelligenceScheduler.Priority = .interactive
    ) async throws -> String {
        if let reason = Self.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }
        return try await condense(
            notes, targetLanguage: targetLanguage, glossary: glossary, priority: priority)
    }

    private func summarizeMaterial(
        _ material: String,
        request: SummaryRequest,
        priority: IntelligenceScheduler.Priority
    ) async throws -> SummaryDraft {
        if let reason = Self.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }

        let condensed = try await condense(
            material, targetLanguage: request.targetLanguage, glossary: request.glossary,
            priority: priority)

        let session = LanguageModelSession(
            instructions: PromptFactory.summaryInstructions(
                recipe: request.recipe,
                targetLanguage: request.targetLanguage,
                glossary: request.glossary))
        // Greedy decoding: summaries want faithfulness, not creativity —
        // sampled decoding made the 3B model invent action items. The draft
        // is built INSIDE the slot because Response<T> isn't Sendable.
        return try await IntelligenceScheduler.shared.run(priority) {
            let response = try await session.respond(
                to: PromptFactory.summaryPrompt(
                    transcriptOrNotes: condensed, targetLanguage: request.targetLanguage),
                generating: GeneratedSummary.self,
                options: GenerationOptions(sampling: .greedy))
            return response.content.structured.draft(for: request)
        }
    }

    /// Map phase: collapses the transcript into notes small enough for the
    /// final structured pass (whose window also holds the response schema
    /// and the output), recursing over the notes themselves when a meeting
    /// is long enough that even its notes overflow.
    private func condense(
        _ text: String, targetLanguage: String, glossary: [String],
        priority: IntelligenceScheduler.Priority, depth: Int = 0
    ) async throws -> String {
        guard text.count > TranscriptFormatter.onDeviceReduceBudget else { return text }
        guard depth < 4 else {
            throw IntelligenceError.providerFailed("transcript did not converge while condensing")
        }

        let chunks = TranscriptFormatter.chunk(
            text, budget: TranscriptFormatter.onDeviceChunkBudget)
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            // Fresh session per chunk: sessions accumulate context and a
            // shared one would overflow the window by the second chunk.
            let session = LanguageModelSession(
                instructions: PromptFactory.notesInstructions(
                    targetLanguage: targetLanguage, glossary: glossary))
            // 250 tokens (~1000 chars) per note from a 4500-char chunk ⇒
            // ≥4× compression per level, so the recursion always converges.
            let note = try await IntelligenceScheduler.shared.run(priority) {
                try await session.respond(
                    to: PromptFactory.notesPrompt(
                        chunk: chunk, index: index, total: chunks.count),
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 250)
                ).content
            }
            notes.append(note)
        }
        return try await condense(
            notes.joined(separator: "\n"),
            targetLanguage: targetLanguage, glossary: glossary,
            priority: priority, depth: depth + 1)
    }
}

// MARK: - Guided generation shapes

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A structured, faithful meeting summary")
struct GeneratedSummary {
    @Guide(description: "One-paragraph overview of what the meeting was about and its outcome")
    var overview: String

    @Guide(
        description:
            "One entry per instructed section heading, in the instructed order. Do NOT add a section for action items — they go in the actionItems field only"
    )
    var sections: [GeneratedSection]

    @Guide(
        description:
            "ONLY commitments someone explicitly stated in the material, quoted with its owner's speaker label. Empty array when nobody committed to anything"
    )
    var actionItems: [GeneratedActionItem]
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "One summary section")
struct GeneratedSection {
    @Guide(description: "The section heading, exactly as instructed")
    var heading: String
    @Guide(description: "Terse factual bullet points; empty if nothing applies")
    var bullets: [String]
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A single action item")
struct GeneratedActionItem {
    @Guide(description: "What was committed to")
    var text: String
    @Guide(description: "Speaker label of the owner (e.g. Me, S1), or empty string if not stated")
    var owner: String
}

@available(macOS 26.0, iOS 26.0, *)
extension GeneratedSummary {
    var structured: StructuredSummary {
        StructuredSummary(
            overview: overview,
            sections: sections.map { .init(heading: $0.heading, bullets: $0.bullets) },
            actionItems: actionItems.map { .init(text: $0.text, owner: $0.owner) }
        )
    }
}
#endif
