import IntelligenceKit
import PortavozCore
import StorageKit

/// User-selectable summary engines. Selection policy remains an app adapter;
/// application workflows receive only this stable value.
public enum SummaryEngine: String, CaseIterable, Sendable {
    case appleOnDevice
    case ollama
    case mlx
}

/// Reuse behavior supported by a concrete summary provider.
public enum SummaryRegenerationReusePolicy: Sendable {
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
}

/// Provider capability consumed by the regeneration workflow.
///
/// Concrete model construction and availability checks stay in the app. The
/// translation operation is called only for providers that opt into the pivot
/// reuse policy.
public protocol SummaryRegenerationProvider: Sendable {
    var providerID: String { get }
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
        fingerprint: String,
        language: String?
    ) async throws -> SummaryRegenerationSnapshot?
    func saveRegeneratedSummary(_ draft: SummaryDraft) async throws
}

extension MeetingStore: SummaryRegenerationStore {
    public func regenerationContextItems(for meetingID: MeetingID) async throws -> [ContextItem] {
        try await contextItems(for: meetingID)
    }

    public func regenerationSummary(
        _ meetingID: MeetingID,
        fingerprint: String,
        language: String?
    ) async throws -> SummaryRegenerationSnapshot? {
        guard let stored = try await latestSummary(
            meetingID,
            fingerprint: fingerprint,
            language: language)
        else { return nil }
        return SummaryRegenerationSnapshot(draft: stored.draft, version: stored.version)
    }

    public func saveRegeneratedSummary(_ draft: SummaryDraft) async throws {
        _ = try await saveSummary(draft)
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

    public init(
        store: any SummaryRegenerationStore,
        preferences: any SummaryRegenerationPreferences,
        providers: any SummaryRegenerationProviderResolver
    ) {
        self.store = store
        self.preferences = preferences
        self.providers = providers
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
            switch provider.reusePolicy {
            case .none:
                return await generate(summaryRequest, with: provider)
            case .fingerprintCacheAndTranslationPivot:
                return await regenerateWithReuse(summaryRequest, provider: provider)
            }
        }
    }

    private func regenerateWithReuse(
        _ request: SummaryRequest,
        provider: any SummaryRegenerationProvider
    ) async -> SummaryRegenerationResult {
        let fingerprint = SummaryFingerprint.compute(
            request: request, providerID: provider.providerID)
        if let exact = try? await store.regenerationSummary(
            request.meetingID,
            fingerprint: fingerprint,
            language: request.targetLanguage) {
            return .unchanged(version: exact.version)
        }
        if let pivot = try? await store.regenerationSummary(
            request.meetingID,
            fingerprint: fingerprint,
            language: nil),
            let translated = try? await provider.translate(
                pivot.draft,
                to: request.targetLanguage,
                glossary: request.glossary) {
            return .completed(persisted: await persist(translated))
        }
        return await generate(request, with: provider)
    }

    private func generate(
        _ request: SummaryRequest,
        with provider: any SummaryRegenerationProvider
    ) async -> SummaryRegenerationResult {
        do {
            let draft = try await provider.summarize(request)
            return .completed(persisted: await persist(draft))
        } catch {
            return .generationFailed(provider.failurePresentation)
        }
    }

    private func persist(_ draft: SummaryDraft) async -> Bool {
        do {
            try await store.saveRegeneratedSummary(draft)
            return true
        } catch {
            return false
        }
    }
}
