import Foundation
import Observation
import TranscriptionKit

@MainActor
protocol AppleSpeechPreparationClient: AnyObject {
    func current(language: String?) async throws -> SpeechAnalyzerLiveReadiness
    func prepare(language: String) async throws
}

/// Settings owns the only explicit Apple asset request. Reading capability
/// never starts a download, and a failed request never changes the live
/// engine selection or falls back silently at capture time.
@MainActor
@Observable
final class AppleSpeechPreparationModel {
    enum Phase: Equatable {
        case checking
        case languageRequired
        case unavailable
        case unsupported
        case needsDownload
        case blockedByCapture
        case preparing
        case ready
        case failed
    }

    private var phases: [String: Phase] = [:]
    @ObservationIgnored private var generation: [String: UInt64] = [:]
    private var preparingLanguage: String?
    @ObservationIgnored private let client: any AppleSpeechPreparationClient

    init(client: any AppleSpeechPreparationClient) {
        self.client = client
    }

    func phase(for language: String?) -> Phase {
        guard let language, ["en", "es"].contains(language) else { return .languageRequired }
        return phases[language] ?? .checking
    }

    func isPreparingAnotherLanguage(_ language: String?) -> Bool {
        guard let language else { return false }
        return preparingLanguage != nil && preparingLanguage != language
    }

    func refresh(language: String?) async {
        guard let language, ["en", "es"].contains(language),
              preparingLanguage != language else { return }
        let next = (generation[language] ?? 0) &+ 1
        generation[language] = next
        phases[language] = .checking
        do {
            let readiness = try await client.current(language: language)
            guard !Task.isCancelled, generation[language] == next else { return }
            phases[language] = Self.phase(for: readiness)
        } catch is CancellationError {
            // A departing Settings task never overwrites the previous receipt.
        } catch {
            guard generation[language] == next else { return }
            phases[language] = .failed
        }
    }

    func prepare(language: String?) async {
        guard let language, ["en", "es"].contains(language),
              phases[language] == .needsDownload || phases[language] == .blockedByCapture,
              preparingLanguage == nil else { return }
        preparingLanguage = language
        generation[language, default: 0] &+= 1
        phases[language] = .preparing
        defer { preparingLanguage = nil }
        do {
            try await client.prepare(language: language)
            let readiness = try await client.current(language: language)
            phases[language] = Self.phase(for: readiness)
        } catch is CancellationError {
            phases[language] = .needsDownload
        } catch AppResourceGovernorAdmissionError.activeCaptureModelConflict {
            phases[language] = .blockedByCapture
        } catch {
            phases[language] = .failed
        }
    }

    private static func phase(for readiness: SpeechAnalyzerLiveReadiness) -> Phase {
        switch readiness {
        case .languageRequired: .languageRequired
        case .unavailable: .unavailable
        case .unsupported: .unsupported
        case .needsDownload: .needsDownload
        case .ready: .ready
        }
    }
}

@MainActor
final class AppAppleSpeechPreparationClient: AppleSpeechPreparationClient {
    private let captureState: AppResourceCaptureState

    init(captureState: AppResourceCaptureState) {
        self.captureState = captureState
    }

    func current(language: String?) async throws -> SpeechAnalyzerLiveReadiness {
        guard #available(macOS 26.0, *) else { return .unavailable }
        return try await SpeechAnalyzerLiveEngine.readiness(language: language)
    }

    func prepare(language: String) async throws {
        guard captureState.current == .inactive else {
            throw AppResourceGovernorAdmissionError.activeCaptureModelConflict
        }
        guard #available(macOS 26.0, *) else {
            throw SpeechAnalyzerLiveReadiness.unavailable
        }
        _ = try await SpeechAnalyzerEngine.ensureAssets(language: language)
    }
}
