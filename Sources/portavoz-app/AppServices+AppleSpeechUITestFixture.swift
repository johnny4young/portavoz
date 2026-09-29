import Foundation
import TranscriptionKit

/// A disposable Settings-only asset receipt. It never changes the serving
/// engine or calls Apple Speech; real model paths remain separately qualified.
@MainActor
final class AppleSpeechUITestFixture: AppleSpeechPreparationClient {
    private var installed: Set<String> = []
    private var failsFirstInspection = false

    private init(failsFirstInspection: Bool) {
        self.failsFirstInspection = failsFirstInspection
    }

    static func make(
        arguments: [String], usesTemporaryStore: Bool
    ) -> AppleSpeechUITestFixture? {
        guard usesTemporaryStore else { return nil }
        if arguments.contains("-seed-apple-speech-retry-settings") {
            return AppleSpeechUITestFixture(failsFirstInspection: true)
        }
        guard arguments.contains("-seed-apple-speech-settings") else { return nil }
        return AppleSpeechUITestFixture(failsFirstInspection: false)
    }

    func current(language: String?) async throws -> SpeechAnalyzerLiveReadiness {
        guard let language, ["en", "es"].contains(language) else { return .languageRequired }
        if failsFirstInspection {
            failsFirstInspection = false
            throw FixtureInspectionFailure.unavailable
        }
        let locale = language == "en" ? "en_US" : "es_ES"
        return installed.contains(language) ? .ready(locale) : .needsDownload(locale)
    }

    func prepare(language: String) async throws {
        guard ["en", "es"].contains(language) else {
            throw SpeechAnalyzerLiveReadiness.languageRequired
        }
        installed.insert(language)
    }
}

private enum FixtureInspectionFailure: Error {
    case unavailable
}
