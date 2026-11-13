import Foundation
import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class LiveSpeechSelectionTests: XCTestCase {
    func testAbsentCorruptOrRetiredPreferencesDefaultMeetingsToParakeet() async throws {
        let suite = "live-speech-selection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LiveSpeechSelection.meeting(defaults: defaults), .parakeet)
        defaults.set("unknown-engine", forKey: LiveSpeechSelection.meetingKey)
        XCTAssertEqual(LiveSpeechSelection.meeting(defaults: defaults), .parakeet)
        defaults.set("parakeetUltra", forKey: LiveSpeechSelection.meetingKey)
        XCTAssertEqual(LiveSpeechSelection.meeting(defaults: defaults), .parakeet,
                       "1.x's dictation-only Ultra never reaches a meeting")
        defaults.set(LiveSpeechSelection.appleSpeech.rawValue, forKey: LiveSpeechSelection.meetingKey)
        XCTAssertEqual(LiveSpeechSelection.meeting(defaults: defaults), .appleSpeech)
    }

    func testSelectedAppleWithAutomaticLanguageNeverStartsAModelLoad() async throws {
        let suite = "live-speech-route-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(LiveSpeechSelection.appleSpeech.rawValue,
                     forKey: LiveSpeechSelection.meetingKey)
        defaults.set("auto", forKey: MeetingLanguagePreferences.transcriptKey)
        let services = try AppServices(
            arguments: ["portavoz-app", "-use-temp-store"], defaults: defaults)

        XCTAssertNil(try services.acquireResidentLiveTranscriptionRuntime())
        do {
            _ = try await services.acquireLiveTranscriptionRuntime()
            XCTFail("Automatic language must not silently launch a fixed-locale engine")
        } catch SpeechAnalyzerLiveReadiness.languageRequired {
            // Rejected before consulting the Speech daemon.
        } catch {
            XCTFail("Expected languageRequired, got \(type(of: error))")
        }
        XCTAssertNil(services.liveSpeechRuntimeLoad)
        XCTAssertNil(services.transcriber)
    }
}
