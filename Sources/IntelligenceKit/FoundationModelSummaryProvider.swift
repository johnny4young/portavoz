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
    /// Identity for `SummaryFingerprint` (the OS model has no queryable
    /// version; macOS updates that change it are rare enough to accept).
    public static let providerID = "foundation-models"

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
        let transcript = TranscriptFormatter.formatWithEvidence(
            segments: request.segments, speakers: request.speakers)
        var draft = try await summarizeMaterial(
            transcript.text,
            request: request,
            priority: priority,
            includeEvidence: true)
        draft.fingerprint = SummaryFingerprint.compute(
            request: request, providerID: Self.providerID)
        return draft
    }

    // Positional translation with section-by-section shape validation;
    // the body is legitimately long. Splitting remains technical debt.
    /// D25's pivot: translates an existing snapshot to another language for
    /// a fraction of a full re-summarization (the material is already
    /// distilled — ~2k chars instead of the whole transcript).
    ///
    /// The pivot's markdown is parsed back into its structure and the model
    /// translates through a MIRRORED schema (overview / sections / items):
    /// handed one opaque markdown string instead, the 3B truncated to the
    /// first paragraph (caught by the gated test). Sections and action
    /// items translate positionally — heading count must survive, owners
    /// carry over by index — and any shape mismatch throws so the caller
    /// falls back to a full re-summarization instead of storing a lossy
    /// translation. The result keeps the pivot's fingerprint: same
    /// material, new language.
    public func translate( // swiftlint:disable:this function_body_length
        _ pivot: SummaryDraft,
        to targetLanguage: String,
        glossary: [String] = [],
        priority: IntelligenceScheduler.Priority = .interactive
    ) async throws -> SummaryDraft {
        if let reason = Self.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }
        // The 4096-token window holds input + output; a pivot too big to
        // fit twice must go the full-summarize route instead.
        guard pivot.markdown.count <= 3200 else {
            throw IntelligenceError.providerFailed("pivot summary too large to translate in-window")
        }
        guard let structure = StructuredSummary.parse(markdown: pivot.markdown) else {
            throw IntelligenceError.providerFailed("pivot summary has no recognizable structure")
        }

        // One call per piece — overview, then each section. Handed the
        // whole summary at once (even schema-guided), the 3B invented
        // extra sections; piecewise, the structure survives by
        // CONSTRUCTION and each call is small. Still a fraction of a full
        // re-summarization.
        let instructions = PromptFactory.translationInstructions(
            targetLanguage: targetLanguage, glossary: glossary)

        let overviewPrompt = PromptFactory.translationPrompt(
            markdown: structure.overview, actionItems: "", targetLanguage: targetLanguage)
        let overview = try await IntelligenceScheduler.shared.run(priority) {
            try await LanguageModelSession(instructions: instructions).respond(
                to: overviewPrompt,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 350)
            ).content
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overview.isEmpty else {
            throw IntelligenceError.providerFailed("translation came back empty")
        }

        var sections: [StructuredSummary.Section] = []
        for section in structure.sections {
            let sectionMarkdown = StructuredSummary(
                overview: "", sections: [section], actionItems: []
            ).markdown(recipe: .general)
            let prompt = PromptFactory.translationPrompt(
                markdown: sectionMarkdown, actionItems: "", targetLanguage: targetLanguage)
            let translated = try await IntelligenceScheduler.shared.run(priority) {
                let response = try await LanguageModelSession(instructions: instructions)
                    .respond(
                        to: prompt,
                        generating: TranslatedSection.self,
                        options: GenerationOptions(sampling: .greedy))
                return StructuredSummary.Section(
                    heading: response.content.heading, bullets: response.content.bullets)
            }
            guard translated.bullets.count == section.bullets.count else {
                throw IntelligenceError.providerFailed(
                    "translation lost bullets in \"\(section.heading)\" (\(translated.bullets.count)/\(section.bullets.count))"
                )
            }
            sections.append(translated)
        }

        // Call 2: the action items alone, positionally. Fresh ActionItem
        // IDs: snapshots never share rows (the PK would collide on save),
        // and a new version starts unchecked.
        var items: [ActionItem] = []
        var renderedItems: [StructuredSummary.Item] = []
        if !pivot.actionItems.isEmpty {
            let itemsBlock = pivot.actionItems.enumerated()
                .map { "\($0.offset + 1). \($0.element.text)" }
                .joined(separator: "\n")
            let itemsPrompt = PromptFactory.translationPrompt(
                markdown: "", actionItems: itemsBlock, targetLanguage: targetLanguage)
            let texts = try await IntelligenceScheduler.shared.run(priority) {
                try await LanguageModelSession(instructions: instructions).respond(
                    to: itemsPrompt,
                    generating: TranslatedItems.self,
                    options: GenerationOptions(sampling: .greedy)
                ).content.items
            }
            guard texts.count == pivot.actionItems.count else {
                throw IntelligenceError.providerFailed(
                    "translation lost action items (\(texts.count)/\(pivot.actionItems.count))")
            }
            items = zip(pivot.actionItems, texts).map { original, text in
                ActionItem(text: text, ownerSpeakerID: original.ownerSpeakerID)
            }
            // Owner labels for the rendered block come from the pivot's own
            // markdown ("— S1" suffixes), positionally when they line up.
            let owners = structure.actionItems.count == texts.count
                ? structure.actionItems.map(\.owner)
                : Array(repeating: "", count: texts.count)
            renderedItems = zip(texts, owners).map { StructuredSummary.Item(text: $0, owner: $1) }
        }

        let complete = StructuredSummary(
            overview: overview, sections: sections, actionItems: renderedItems)
        return SummaryDraft(
            meetingID: pivot.meetingID,
            recipeID: pivot.recipeID,
            language: targetLanguage,
            markdown: complete.markdown(recipe: .general),
            actionItems: items,
            fingerprint: pivot.fingerprint,
            claims: pivot.claims.map { claim in
                SummaryClaim(
                    kind: claim.kind,
                    sourceTranscriptRevision: claim.sourceTranscriptRevision,
                    evidenceSegmentIDs: claim.evidenceSegmentIDs,
                    unavailableEvidenceCount: claim.unavailableEvidenceCount)
            },
            decisionEvidence: StructuredSummary.translatedDecisionEvidence(
                from: pivot,
                into: sections),
            actionItemEvidence: StructuredSummary.translatedActionItemEvidence(
                from: pivot,
                into: items))
    }

    /// Reduce phase over already-condensed notes (the live rolling summary
    /// accumulates them window by window and re-renders from here).
    public func summarizeNotes(
        _ notes: String,
        request: SummaryRequest,
        priority: IntelligenceScheduler.Priority = .interactive
    ) async throws -> SummaryDraft {
        try await summarizeMaterial(
            notes,
            request: request,
            priority: priority,
            includeEvidence: false)
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
        priority: IntelligenceScheduler.Priority,
        includeEvidence: Bool
    ) async throws -> SummaryDraft {
        if let reason = Self.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }

        // D28: the user's notes ride the FINAL pass as intent. They share
        // the 4096-token window with the condensed material, so the reduce
        // target shrinks by exactly what the notes block occupies.
        let notesBlock = PromptFactory.notesBlock(request.contextItems)
        let condensed = try await condense(
            material, targetLanguage: request.targetLanguage, glossary: request.glossary,
            priority: priority,
            reduceBudget: TranscriptFormatter.onDeviceReduceBudget - notesBlock.count)

        let session = LanguageModelSession(
            instructions: PromptFactory.summaryInstructions(
                recipe: request.recipe,
                targetLanguage: request.targetLanguage,
                glossary: request.glossary,
                hasUserNotes: !notesBlock.isEmpty))
        // Greedy decoding: summaries want faithfulness, not creativity —
        // sampled decoding made the 3B model invent action items. The draft
        // is built INSIDE the slot because Response<T> isn't Sendable.
        return try await IntelligenceScheduler.shared.run(priority) {
            let response = try await session.respond(
                to: PromptFactory.summaryPrompt(
                    transcriptOrNotes: condensed, targetLanguage: request.targetLanguage,
                    userNotes: notesBlock),
                generating: GeneratedSummary.self,
                options: GenerationOptions(sampling: .greedy))
            return response.content.structured.draft(
                for: request,
                includeEvidence: includeEvidence)
        }
    }

    /// Map phase: collapses the transcript into notes small enough for the
    /// final structured pass (whose window also holds the response schema
    /// and the output), recursing over the notes themselves when a meeting
    /// is long enough that even its notes overflow.
    private func condense(
        _ text: String, targetLanguage: String, glossary: [String],
        priority: IntelligenceScheduler.Priority,
        reduceBudget: Int = TranscriptFormatter.onDeviceReduceBudget,
        depth: Int = 0
    ) async throws -> String {
        guard text.count > max(reduceBudget, 600) else { return text }
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
            priority: priority, reduceBudget: reduceBudget, depth: depth + 1)
    }
}

// MARK: - Guided generation shapes

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "One translated summary section")
struct TranslatedSection {
    @Guide(description: "The section heading, translated")
    var heading: String
    @Guide(
        description:
            "The section's bullets translated, same order and count; when a bullet starts with \"▸ \", keep that prefix"
    )
    var bullets: [String]
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A list of action items translated into another language")
struct TranslatedItems {
    @Guide(
        description:
            "One translated entry per input numbered line, same order and count, without the numbers"
    )
    var items: [String]
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A structured, faithful meeting summary")
struct GeneratedSummary {
    @Guide(description: "One-paragraph overview of what the meeting was about and its outcome")
    var overview: String

    @Guide(
        description:
            "Up to 4 exact E-tags from the material that directly support the overview; empty when none apply"
    )
    var overviewEvidence: [String]

    // Schema guide descriptions (@Guide): one-line prompts;
    // partir el string no aporta y complica el prompt.
    // swiftlint:disable line_length
    @Guide(
        description:
            "Exactly one entry per instructed section heading, in the instructed order. Keep bullets and bulletEvidence empty when nothing applies; commitments still go in actionItems"
    )
    var sections: [GeneratedSection]

    @Guide(
        description:
            "ONLY commitments someone explicitly stated in the material, quoted with its owner's speaker label. Empty array when nobody committed to anything"
    )
    // swiftlint:enable line_length
    var actionItems: [GeneratedActionItem]
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "One summary section")
struct GeneratedSection {
    @Guide(description: "The section heading, exactly as instructed")
    var heading: String
    @Guide(description: "Terse factual bullet points; empty if nothing applies")
    var bullets: [String]
    @Guide(
        description:
            "One exact E-tag array per bullet, same order and count; "
            + "use tags only for instructed decision sections and [] otherwise"
    )
    var bulletEvidence: [[String]]
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A single action item")
struct GeneratedActionItem {
    @Guide(description: "What was committed to")
    var text: String
    @Guide(description: "Speaker label of the owner (e.g. Me, S1), or empty string if not stated")
    var owner: String
    @Guide(
        description:
            "Up to 4 exact E-tags from the material that directly support this commitment; empty when none apply"
    )
    var evidence: [String]
}

@available(macOS 26.0, iOS 26.0, *)
extension GeneratedSummary {
    var structured: StructuredSummary {
        StructuredSummary(
            overview: overview,
            sections: sections.map {
                .init(
                    heading: $0.heading,
                    bullets: $0.bullets,
                    bulletEvidence: $0.bulletEvidence)
            },
            actionItems: actionItems.map {
                .init(text: $0.text, owner: $0.owner, evidence: $0.evidence)
            },
            overviewEvidence: overviewEvidence
        )
    }
}
#endif
