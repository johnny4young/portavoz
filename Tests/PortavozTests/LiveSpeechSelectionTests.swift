import Foundation
import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class LiveSpeechSelectionTests: XCTestCase {
    func testAbsentOrCorruptPreferencesDefaultMeetingsToParakeetAndDictationToUltra() async throws {
        let suite = "live-speech-selection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LiveSpeechSelection.meeting(defaults: defaults), .parakeet)
        XCTAssertEqual(LiveSpeechSelection.dictation(defaults: defaults), .parakeetUltra)
        defaults.set("unknown-engine", forKey: LiveSpeechSelection.meetingKey)
        defaults.set("", forKey: LiveSpeechSelection.dictationKey)
        XCTAssertEqual(LiveSpeechSelection.meeting(defaults: defaults), .parakeet)
        XCTAssertEqual(LiveSpeechSelection.dictation(defaults: defaults), .parakeetUltra)
        defaults.set(LiveSpeechSelection.parakeet.rawValue, forKey: LiveSpeechSelection.dictationKey)
        XCTAssertEqual(LiveSpeechSelection.dictation(defaults: defaults), .parakeet,
                       "an explicit Parakeet choice survives the new default")
    }

    func testTheDefaultUltraNeitherDownloadsNorBlocksDictation() async throws {
        let suite = "live-speech-ultra-default-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:], defaults: defaults)
        let checkpoint = await services.dictationCheckpoint()
        XCTAssertEqual(checkpoint, .v3, "dictation keeps Parakeet until Ultra is downloaded")
        XCTAssertNil(services.parakeetUltraDownload, "a default is not consent to download 613 MB")
    }

    func testSelectedAppleWithAutomaticLanguageNeverStartsAModelLoad() async throws {
        let suite = "live-speech-route-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(LiveSpeechSelection.appleSpeech.rawValue,
                     forKey: LiveSpeechSelection.meetingKey)
        defaults.set(LiveSpeechSelection.appleSpeech.rawValue,
                     forKey: LiveSpeechSelection.dictationKey)
        defaults.set("auto", forKey: MeetingLanguagePreferences.transcriptKey)
        defaults.set("auto", forKey: DictationController.languageKey)
        let services = try AppServices(
            arguments: ["portavoz-app", "-use-temp-store"], defaults: defaults)

        XCTAssertNil(try services.acquireResidentLiveTranscriptionRuntime())
        for purpose in [LiveSpeechPurpose.meeting, .dictation] {
            do {
                _ = try await services.acquireLiveTranscriptionRuntime(for: purpose)
                XCTFail("Automatic language must not silently launch a fixed-locale engine")
            } catch SpeechAnalyzerLiveReadiness.languageRequired {
                // Rejected before consulting the Speech daemon.
            } catch {
                XCTFail("Expected languageRequired, got \(type(of: error))")
            }
        }
        XCTAssertNil(services.liveSpeechRuntimeLoad)
        XCTAssertNil(services.transcriber)
    }
}
