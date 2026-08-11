import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

public enum CompanionRegenerationUnavailability: Equatable, Sendable {
    case requiresMacOS26
    case appleOnDevice(reason: String)
}

/// One complete attempt to rebuild the current Apuntador snapshot.
/// `completed == false` means callers must preserve every prior card.
public struct CompanionRegenerationPass: Sendable {
    public let artifacts: [CompanionGenerationArtifact]
    public let terminalRuns: [GenerationRun]
    public let completed: Bool

    public init(
        artifacts: [CompanionGenerationArtifact],
        terminalRuns: [GenerationRun] = [],
        completed: Bool
    ) {
        self.artifacts = artifacts
        self.terminalRuns = terminalRuns
        self.completed = completed
    }
}

public struct RegenerateCompanionCardsRequest: Sendable {
    public let meetingID: MeetingID
    public let material: MeetingTranscriptGenerationMaterial

    public init(
        meetingID: MeetingID,
        material: MeetingTranscriptGenerationMaterial
    ) {
        self.meetingID = meetingID
        self.material = material
    }
}

public enum CompanionRegenerationProviderResult: Sendable {
    case unavailable(CompanionRegenerationUnavailability)
    case pass(CompanionRegenerationPass)
}

/// App-owned capability boundary. ApplicationKit decides publication policy;
/// the adapter decides whether and how the Apple model pipeline can run.
public protocol CompanionRegenerationProvider: Sendable {
    func regenerate(
        _ request: RegenerateCompanionCardsRequest
    ) async -> CompanionRegenerationProviderResult
}

public protocol CompanionRegenerationStore: Sendable {
    func saveCompanionRegenerationRun(
        _ run: GenerationRun,
        sourceTranscriptRevision: Int
    ) async throws
    func replaceRegeneratedCompanionCards(
        _ artifacts: [CompanionGenerationArtifact],
        for meetingID: MeetingID
    ) async throws
}

extension MeetingStore: CompanionRegenerationStore {
    public func saveCompanionRegenerationRun(
        _ run: GenerationRun,
        sourceTranscriptRevision: Int
    ) async throws {
        try await saveReviewedCompanionGenerationRun(
            run,
            sourceTranscriptRevision: sourceTranscriptRevision)
    }

    public func replaceRegeneratedCompanionCards(
        _ artifacts: [CompanionGenerationArtifact],
        for meetingID: MeetingID
    ) async throws {
        try await replaceReviewedCompanionCards(artifacts, for: meetingID)
    }
}

public enum RegenerateCompanionCardsResult: Equatable, Sendable {
    case replaced(count: Int)
    case unavailable(CompanionRegenerationUnavailability)
    case preserved
    case persistenceFailed
}

/// Explicitly rebuilds the complete Apuntador snapshot from the reviewed
/// transcript. Correction writes never call this use case. Incomplete model
/// work and persistence races retain the prior, honestly stale snapshot.
public struct RegenerateCompanionCards: ApplicationUseCase {
    private let store: any CompanionRegenerationStore
    private let provider: any CompanionRegenerationProvider

    public init(
        store: any CompanionRegenerationStore,
        provider: any CompanionRegenerationProvider
    ) {
        self.store = store
        self.provider = provider
    }

    public func execute(
        _ request: RegenerateCompanionCardsRequest
    ) async -> RegenerateCompanionCardsResult {
        let pass: CompanionRegenerationPass
        switch await provider.regenerate(request) {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .pass(let completedPass):
            pass = completedPass
        }

        for run in pass.terminalRuns {
            try? await store.saveCompanionRegenerationRun(
                run,
                sourceTranscriptRevision: request.material.baseTranscriptRevision)
        }
        guard pass.completed, pass.terminalRuns.isEmpty else { return .preserved }
        do {
            try await store.replaceRegeneratedCompanionCards(
                pass.artifacts,
                for: request.meetingID)
            return .replaced(count: pass.artifacts.count)
        } catch {
            return .persistenceFailed
        }
    }
}
