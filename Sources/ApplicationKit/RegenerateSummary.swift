import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// User-selectable summary engines. Selection policy remains an app adapter;
/// application workflows receive only this stable value.
public enum SummaryEngine: String, CaseIterable, Sendable, Equatable {
    case appleOnDevice
    case ollama
    case mlx
}

/// Reuse behavior supported by a concrete summary provider.
public enum SummaryRegenerationReusePolicy: String, Sendable {
    /// The released Ollama/MLX path generates directly.
    case none
    /// Apple FM checks exact material first, then translates a language pivot.
    case fingerprintCacheAndTranslationPivot
}

/// Released error UX differs between configured local models and Apple FM.
public enum SummaryRegenerationFailurePresentation: Equatable, Sendable {
    case localModelNotice
    case silent
}

/// Why the Apple summary fallback cannot run on this Mac.
public enum SummaryRegenerationUnavailability: Equatable, Sendable {
    case requiresMacOS26
    case appleOnDevice(reason: String)
    case ollamaModelNotSelected
    case mlxModelNotDownloaded
}

/// Provider capability consumed by the regeneration workflow.
///
/// Concrete model construction and availability checks stay in the app. The
/// translation operation is called only for providers that opt into the pivot
/// reuse policy.
public protocol SummaryRegenerationProvider: Sendable {
    var providerID: String { get }
    var modelID: String { get }
    var modelRevision: String? { get }
    var reusePolicy: SummaryRegenerationReusePolicy { get }
    var failurePresentation: SummaryRegenerationFailurePresentation { get }

    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft
    func translate(
        _ pivot: SummaryDraft,
        to targetLanguage: String,
        glossary: [String]
    ) async throws -> SummaryDraft
}

public enum SummaryRegenerationProviderResolution: Sendable {
    case available(any SummaryRegenerationProvider)
    case unavailable(SummaryRegenerationUnavailability)
}

/// Resolves the global engine or a one-meeting override without exposing
/// platform preference storage, model locations, or availability policy.
public protocol SummaryRegenerationProviderResolver: Sendable {
    func resolve(
        override: SummaryEngine?
    ) async -> SummaryRegenerationProviderResolution
}

/// Reads app-owned summary preferences without leaking their platform store.
public protocol SummaryRegenerationPreferences: Sendable {
    func glossary() async -> [String]
}

public struct SummaryRegenerationSnapshot: Sendable {
    public let draft: SummaryDraft
    public let version: Int

    public init(draft: SummaryDraft, version: Int) {
        self.draft = draft
        self.version = version
    }
}

/// Narrow persistence port for regeneration material, reuse, and snapshots.
public protocol SummaryRegenerationStore: Sendable {
    func regenerationContextItems(for meetingID: MeetingID) async throws -> [ContextItem]
    func regenerationSummary(
        _ meetingID: MeetingID,
        recipeID: String,
        fingerprint: String,
        language: String?
    ) async throws -> SummaryRegenerationSnapshot?
    func saveRegeneratedSummary(
        _ draft: SummaryDraft,
        generationRun: GenerationRun
    ) async throws
    func saveRegenerationRun(_ run: GenerationRun) async throws
}

extension MeetingStore: SummaryRegenerationStore {
    public func regenerationContextItems(for meetingID: MeetingID) async throws -> [ContextItem] {
        try await contextItems(for: meetingID)
    }

    public func regenerationSummary(
        _ meetingID: MeetingID,
        recipeID: String,
        fingerprint: String,
        language: String?
    ) async throws -> SummaryRegenerationSnapshot? {
        guard let stored = try await latestSummary(
            meetingID,
            recipeID: recipeID,
            fingerprint: fingerprint,
            language: language)
        else { return nil }
        return SummaryRegenerationSnapshot(draft: stored.draft, version: stored.version)
    }

    public func saveRegeneratedSummary(
        _ draft: SummaryDraft,
        generationRun: GenerationRun
    ) async throws {
        _ = try await saveSummary(draft, generationRun: generationRun)
    }

    public func saveRegenerationRun(_ run: GenerationRun) async throws {
        try await saveGenerationRun(run)
    }
}

public struct RegenerateSummaryRequest: Sendable {
    public let meetingID: MeetingID
    public let segments: [TranscriptSegment]
    public let speakers: [Speaker]
    public let recipe: Recipe
    public let targetLanguage: String
    public let providerOverride: SummaryEngine?

    public init(
        meetingID: MeetingID,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        recipe: Recipe,
        targetLanguage: String,
        providerOverride: SummaryEngine? = nil
    ) {
        self.meetingID = meetingID
        self.segments = segments
        self.speakers = speakers
        self.recipe = recipe
        self.targetLanguage = targetLanguage
        self.providerOverride = providerOverride
    }
}

/// Explicit outcome consumed by Meeting Detail's existing notice/error UX.
public enum SummaryRegenerationResult: Equatable, Sendable {
    /// Generation completed. Persistence is explicit even though the released
    /// presentation path invalidates the library after either value.
    case completed(persisted: Bool)
    case unchanged(version: Int)
    case unavailable(SummaryRegenerationUnavailability)
    case generationFailed(SummaryRegenerationFailurePresentation)
}

/// Rebuilds one summary while preserving provider overrides, notes, glossary,
/// Apple fingerprint reuse, translation pivot, and released failure behavior.
public struct RegenerateSummary: ApplicationUseCase {
    private let store: any SummaryRegenerationStore
    private let preferences: any SummaryRegenerationPreferences
    private let providers: any SummaryRegenerationProviderResolver
    private let makeGenerationRunID: @Sendable () -> GenerationRunID
    private let now: @Sendable () -> Date

    public init(
        store: any SummaryRegenerationStore,
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

    public func execute(_ request: RegenerateSummaryRequest) async -> SummaryRegenerationResult {
        let contextItems = (try? await store.regenerationContextItems(for: request.meetingID)) ?? []
        let glossary = await preferences.glossary()
        let summaryRequest = SummaryRequest(
            meetingID: request.meetingID,
            segments: request.segments,
            speakers: request.speakers,
            recipe: request.recipe,
            targetLanguage: request.targetLanguage,
            glossary: glossary,
            contextItems: contextItems)

        switch await providers.resolve(override: request.providerOverride) {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .available(let provider):
            let fingerprint = SummaryFingerprint.compute(
                request: summaryRequest,
                providerID: provider.providerID)
            switch provider.reusePolicy {
            case .none:
                return await generate(
                    summaryRequest,
                    fingerprint: fingerprint,
                    with: provider)
            case .fingerprintCacheAndTranslationPivot:
                return await regenerateWithReuse(
                    summaryRequest,
                    fingerprint: fingerprint,
                    provider: provider)
            }
        }
    }

    private func regenerateWithReuse(
        _ request: SummaryRequest,
        fingerprint: String,
        provider: any SummaryRegenerationProvider
    ) async -> SummaryRegenerationResult {
        if let exact = try? await store.regenerationSummary(
            request.meetingID,
            recipeID: request.recipe.id,
            fingerprint: fingerprint,
            language: request.targetLanguage) {
            return .unchanged(version: exact.version)
        }
        if let pivot = try? await store.regenerationSummary(
            request.meetingID,
            recipeID: request.recipe.id,
            fingerprint: fingerprint,
            language: nil) {
            let attempt = generationAttempt(
                request: request,
                provider: provider,
                operation: .translatePivot,
                fingerprint: fingerprint)
            do {
                let translated = try await provider.translate(
                    pivot.draft,
                    to: request.targetLanguage,
                    glossary: request.glossary)
                let run = generationRun(
                    attempt: attempt,
                    outcome: .succeeded,
                    draft: translated)
                return .completed(
                    persisted: await persist(translated, generationRun: run))
            } catch {
                await persistFailedRun(attempt: attempt, error: error)
            }
        }
        return await generate(
            request,
            fingerprint: fingerprint,
            with: provider)
    }

    private func generate(
        _ request: SummaryRequest,
        fingerprint: String,
        with provider: any SummaryRegenerationProvider
    ) async -> SummaryRegenerationResult {
        let attempt = generationAttempt(
            request: request,
            provider: provider,
            operation: .regenerate,
            fingerprint: fingerprint)
        do {
            let draft = try await provider.summarize(request)
            let run = generationRun(
                attempt: attempt,
                outcome: .succeeded,
                draft: draft)
            return .completed(persisted: await persist(draft, generationRun: run))
        } catch {
            await persistFailedRun(attempt: attempt, error: error)
            return .generationFailed(provider.failurePresentation)
        }
    }

    private func persist(
        _ draft: SummaryDraft,
        generationRun: GenerationRun
    ) async -> Bool {
        do {
            try await store.saveRegeneratedSummary(
                draft,
                generationRun: generationRun)
            return true
        } catch {
            return false
        }
    }

    private func generationAttempt(
        request: SummaryRequest,
        provider: any SummaryRegenerationProvider,
        operation: Operation,
        fingerprint: String
    ) -> GenerationAttempt {
        GenerationAttempt(
            request: request,
            providerID: provider.providerID,
            modelID: provider.modelID,
            modelRevision: provider.modelRevision,
            reusePolicy: provider.reusePolicy,
            operation: operation,
            fingerprint: fingerprint,
            startedAt: now())
    }

    private func persistFailedRun(
        attempt: GenerationAttempt,
        error: any Error
    ) async {
        let run = generationRun(
            attempt: attempt,
            outcome: error is CancellationError ? .cancelled : .failed,
            draft: nil)
        // Provenance persistence is intentionally best effort because the
        // released generation-failure presentation must remain unchanged.
        try? await store.saveRegenerationRun(run)
    }

    private func generationRun(
        attempt: GenerationAttempt,
        outcome: GenerationRunOutcome,
        draft: SummaryDraft?
    ) -> GenerationRun {
        GenerationRun(
            id: makeGenerationRunID(),
            meetingID: attempt.request.meetingID,
            kind: .summary,
            providerID: attempt.providerID,
            modelID: attempt.modelID,
            modelRevision: attempt.modelRevision,
            inputFingerprint: attempt.fingerprint,
            configJSON: Self.json([
                "operation": attempt.operation.rawValue,
                "recipeID": attempt.request.recipe.id,
                "reusePolicy": attempt.reusePolicy.rawValue,
                "workflow": "manual-regeneration"
            ]),
            outputLanguage: attempt.request.targetLanguage,
            startedAt: attempt.startedAt,
            finishedAt: now(),
            outcome: outcome,
            metricsJSON: draft.map {
                Self.json([
                    "actionItemCount": $0.actionItems.count,
                    "outputUTF8Bytes": $0.markdown.utf8.count
                ])
            })
    }

    private static func json(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    private enum Operation: String {
        case regenerate
        case translatePivot = "translate-pivot"
    }

    private struct GenerationAttempt {
        let request: SummaryRequest
        let providerID: String
        let modelID: String
        let modelRevision: String?
        let reusePolicy: SummaryRegenerationReusePolicy
        let operation: Operation
        let fingerprint: String
        let startedAt: Date
    }
}
