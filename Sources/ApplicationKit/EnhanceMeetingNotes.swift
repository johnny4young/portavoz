import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// Enhance-my-notes (NOTES-001/D135, the Granola/anarlog pattern): expand
/// the user's own timestamped notes with transcript facts into ONE separate
/// regenerable document. The raw notes are never modified. Mirrors
/// `RegenerateSummary` exactly — same provider resolver (FM/Ollama/MLX/BYOK
/// for free), same fingerprint reuse, same provenance regime — but persists
/// an `EnhancedNote` instead of a summary snapshot.
public struct EnhanceMeetingNotesRequest: Sendable {
    public let meetingID: MeetingID
    public let segments: [TranscriptSegment]
    public let speakers: [Speaker]
    public let targetLanguage: String
    public let providerOverride: SummaryEngine?

    public init(
        meetingID: MeetingID,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        targetLanguage: String,
        providerOverride: SummaryEngine? = nil
    ) {
        self.meetingID = meetingID
        self.segments = segments
        self.speakers = speakers
        self.targetLanguage = targetLanguage
        self.providerOverride = providerOverride
    }
}

public enum EnhanceMeetingNotesResult: Equatable, Sendable {
    case completed(persisted: Bool)
    /// The stored note already matches these exact inputs and language.
    case unchanged
    /// The meeting has no notes to enhance — nothing to do, honestly.
    case noNotes
    case unavailable(SummaryRegenerationUnavailability)
    case generationFailed(SummaryRegenerationFailurePresentation)
}

/// Narrow persistence port; `MeetingStore` satisfies it below.
public protocol EnhancedNotesStore: Sendable {
    func enhancementContextItems(for meetingID: MeetingID) async throws -> [ContextItem]
    func currentEnhancedNote(for meetingID: MeetingID) async throws -> EnhancedNote?
    func saveEnhancedNote(_ note: EnhancedNote, generationRun: GenerationRun) async throws
    func saveEnhancementRun(_ run: GenerationRun) async throws
}

extension MeetingStore: EnhancedNotesStore {
    public func enhancementContextItems(
        for meetingID: MeetingID
    ) async throws -> [ContextItem] {
        try await contextItems(for: meetingID)
    }

    public func currentEnhancedNote(
        for meetingID: MeetingID
    ) async throws -> EnhancedNote? {
        try await enhancedNote(for: meetingID)
    }

    public func saveEnhancementRun(_ run: GenerationRun) async throws {
        try await saveGenerationRun(run)
    }
}

public struct EnhanceMeetingNotes: ApplicationUseCase {
    // The internal structure the shared providers generate against. Not in
    // `Recipe.all` on purpose: it is machinery, not a user-facing template,
    // and its id keeps enhanced-note fingerprints disjoint from every
    // summary cache row.
    // One-line prompt instruction, matching the built-in recipes' style.
    // swiftlint:disable line_length
    static let notesRecipe = Recipe(
        id: "enhanced-notes",
        displayName: "Enhanced notes",
        sections: ["Notes"],
        instructions: "You expand the participant's own notes using the transcript. For EACH note, in the order given: repeat the note's exact text in bold, then add one to three sentences of what the transcript shows around that note's moment — decisions, numbers, names, outcomes. Never rephrase or reorder the user's wording. If the transcript contradicts a note, keep the note and state the tension plainly. Cover only the notes; do not summarize the rest of the meeting. Never invent content."
    )
    // swiftlint:enable line_length

    private let store: any EnhancedNotesStore
    private let preferences: any SummaryRegenerationPreferences
    private let providers: any SummaryRegenerationProviderResolver
    private let makeGenerationRunID: @Sendable () -> GenerationRunID
    private let now: @Sendable () -> Date

    public init(
        store: any EnhancedNotesStore,
        preferences: any SummaryRegenerationPreferences,
        providers: any SummaryRegenerationProviderResolver,
        makeGenerationRunID: @escaping @Sendable () -> GenerationRunID = {
            GenerationRunID()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.preferences = preferences
        self.providers = providers
        self.makeGenerationRunID = makeGenerationRunID
        self.now = now
    }

    public func execute(
        _ request: EnhanceMeetingNotesRequest
    ) async -> EnhanceMeetingNotesResult {
        let notes = ((try? await store.enhancementContextItems(
            for: request.meetingID)) ?? [])
            .filter { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !notes.isEmpty else { return .noNotes }
        let glossary = await preferences.glossary()
        let summaryRequest = SummaryRequest(
            meetingID: request.meetingID,
            segments: request.segments,
            speakers: request.speakers,
            recipe: Self.notesRecipe,
            targetLanguage: request.targetLanguage,
            glossary: glossary,
            contextItems: notes)

        switch await providers.resolve(override: request.providerOverride) {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .available(let provider):
            let fingerprint = SummaryFingerprint.compute(
                request: summaryRequest,
                providerID: provider.providerID)
            if let existing = try? await store.currentEnhancedNote(
                for: request.meetingID),
                existing.inputFingerprint == fingerprint,
                existing.language == request.targetLanguage {
                // Exact material + language already stored: no model
                // operation occurs, so no GenerationRun is created (D62).
                return .unchanged
            }
            return await generate(
                summaryRequest,
                fingerprint: fingerprint,
                with: provider)
        }
    }

    private func generate(
        _ request: SummaryRequest,
        fingerprint: String,
        with provider: any SummaryRegenerationProvider
    ) async -> EnhanceMeetingNotesResult {
        let startedAt = now()
        do {
            let draft = try await provider.summarize(request)
            let note = EnhancedNote(
                meetingID: request.meetingID,
                markdown: draft.markdown,
                language: request.targetLanguage,
                inputFingerprint: fingerprint,
                createdAt: startedAt)
            let run = generationRun(
                request: request,
                provider: provider,
                fingerprint: fingerprint,
                startedAt: startedAt,
                outcome: .succeeded,
                outputUTF8Bytes: draft.markdown.utf8.count)
            do {
                try await store.saveEnhancedNote(note, generationRun: run)
                return .completed(persisted: true)
            } catch {
                return .completed(persisted: false)
            }
        } catch {
            let run = generationRun(
                request: request,
                provider: provider,
                fingerprint: fingerprint,
                startedAt: startedAt,
                outcome: error is CancellationError ? .cancelled : .failed,
                outputUTF8Bytes: nil)
            // Provenance persistence is intentionally best effort.
            try? await store.saveEnhancementRun(run)
            return .generationFailed(provider.failurePresentation)
        }
    }

    private func generationRun(
        request: SummaryRequest,
        provider: any SummaryRegenerationProvider,
        fingerprint: String,
        startedAt: Date,
        outcome: GenerationRunOutcome,
        outputUTF8Bytes: Int?
    ) -> GenerationRun {
        GenerationRun(
            id: makeGenerationRunID(),
            meetingID: request.meetingID,
            kind: .enhancedNotes,
            providerID: provider.providerID,
            modelID: provider.modelID,
            modelRevision: provider.modelRevision,
            inputFingerprint: fingerprint,
            configJSON: Self.json([
                "operation": "enhance-notes",
                "recipeID": request.recipe.id,
                "noteCount": String(request.contextItems.count),
                "workflow": "manual-enhancement"
            ]),
            outputLanguage: request.targetLanguage,
            startedAt: startedAt,
            finishedAt: now(),
            outcome: outcome,
            metricsJSON: outputUTF8Bytes.map {
                Self.json(["outputUTF8Bytes": String($0)])
            })
    }

    /// Deterministic content-free JSON, same convention as RegenerateSummary.
    private static func json(_ payload: [String: String]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys]),
            let text = String(bytes: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
