import Foundation
import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class LiveSpeechSelectionTests: XCTestCase {
    func testCorruptAndAbsentPreferencesKeepParakeetDefault() async throws {
        let suite = "live-speech-selection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LiveSpeechSelection.meeting(defaults: defaults), .parakeet)
        XCTAssertEqual(LiveSpeechSelection.dictation(defaults: defaults), .parakeet)
        defaults.set("unknown-engine", forKey: LiveSpeechSelection.meetingKey)
        defaults.set("", forKey: LiveSpeechSelection.dictationKey)
        XCTAssertEqual(LiveSpeechSelection.meeting(defaults: defaults), .parakeet)
        XCTAssertEqual(LiveSpeechSelection.dictation(defaults: defaults), .parakeet)
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
                // The Tahoe path rejects before consulting the Speech daemon.
            } catch {
                if #available(macOS 26.0, *) {
                    XCTFail("Expected languageRequired, got \(type(of: error))")
                }
            }
        }
        XCTAssertNil(services.liveSpeechRuntimeLoad)
        XCTAssertNil(services.transcriber)
    }
}
