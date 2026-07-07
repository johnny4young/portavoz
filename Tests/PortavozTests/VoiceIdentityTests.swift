import Foundation
import ModelStoreKit
import PortavozCore
import XCTest

@testable import DiarizationKit
@testable import IntelligenceKit

// MARK: - Voiceprint storage (D8: encrypted, deletable, device-only)

final class VoiceprintStoreTests: XCTestCase {
    private var directory: URL!
    private var keyService: String!
    private var store: VoiceprintStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-voice-\(UUID().uuidString)")
        keyService = "app.portavoz.tests.voice.\(UUID().uuidString)"
        store = VoiceprintStore(directory: directory, keyService: keyService)
    }

    override func tearDownWithError() throws {
        try? store.delete()
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripIsEncryptedAtRest() throws {
        let voiceprint = Voiceprint(embedding: (0..<256).map { Float($0) / 256 })
        do {
            try store.save(voiceprint)
        } catch {
            throw XCTSkip("keychain unavailable in this environment: \(error)")
        }

        let loaded = try store.load()
        XCTAssertEqual(loaded?.embedding, voiceprint.embedding)

        // At rest the file must be ciphertext: no float patterns, no JSON.
        let raw = try Data(contentsOf: directory.appendingPathComponent("voiceprint.enc"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("embedding"))
    }

    func testDeleteRemovesFileAndKeyInOneAction() throws {
        do {
            try store.save(Voiceprint(embedding: [1, 2, 3]))
        } catch {
            throw XCTSkip("keychain unavailable: \(error)")
        }
        XCTAssertTrue(store.exists)

        try store.delete()
        XCTAssertFalse(store.exists)
        XCTAssertNil(try SecretStore.get(service: keyService))
        XCTAssertNil(try store.load())
    }

    func testFileWithoutKeyReadsAsAbsent() throws {
        do {
            try store.save(Voiceprint(embedding: [1, 2, 3]))
        } catch {
            throw XCTSkip("keychain unavailable: \(error)")
        }
        // Key vanishes (e.g. keychain reset) → data is unreadable by design.
        try SecretStore.delete(service: keyService)
        XCTAssertNil(try store.load())
    }
}

// MARK: - "Me" via voiceprint in attribution

final class VoiceprintAttributionTests: XCTestCase {
    func testSystemTurnLabeledMeMergesWithHardwareMe() {
        let meeting = MeetingID()
        let segments = [
            TranscriptSegment(
                meetingID: meeting, channel: .microphone, text: "hola desde mi mic",
                startTime: 0, endTime: 2, isFinal: true),
            TranscriptSegment(
                meetingID: meeting, channel: .system, text: "hola desde la sala",
                startTime: 5, endTime: 7, isFinal: true),
            TranscriptSegment(
                meetingID: meeting, channel: .system, text: "yo soy otra persona",
                startTime: 10, endTime: 12, isFinal: true),
        ]
        let turns = [
            SpeakerTurn(voiceLabel: "Me", startTime: 4.5, endTime: 7.5),  // voiceprint match
            SpeakerTurn(voiceLabel: "S1", startTime: 9.5, endTime: 12.5),
        ]

        let attribution = SpeakerAttributor.attribute(
            segments: segments, turns: turns, meetingID: meeting)

        // One single "Me" speaker covers mic AND matched system turns.
        let meSpeakers = attribution.speakers.filter(\.isMe)
        XCTAssertEqual(meSpeakers.count, 1)
        XCTAssertEqual(attribution.segments[0].speakerID, meSpeakers[0].id)
        XCTAssertEqual(attribution.segments[1].speakerID, meSpeakers[0].id)
        XCTAssertNotEqual(attribution.segments[2].speakerID, meSpeakers[0].id)
    }
}

// MARK: - Naming prompts

final class SpeakerNamerPromptTests: XCTestCase {
    func testNamingInstructionsDemandEvidence() {
        let instructions = PromptFactory.namingInstructions()
        XCTAssertTrue(instructions.contains("ONLY with explicit proof"))
        XCTAssertTrue(instructions.contains("empty list"))
        XCTAssertTrue(instructions.contains("Skip the label \"Me\""))
    }
}

// MARK: - Never-trust-verify filter (with calendar candidates)

final class NameSuggestionFilterTests: XCTestCase {
    private let transcript = "[00:00] S1: hola, soy Carolina y llevo el backend"

    func testAcceptsNameProvenByTranscript() {
        let kept = NameSuggestionFilter.validSuggestions(
            [NameSuggestion(label: "S1", name: "Carolina", evidence: "soy Carolina")],
            transcript: transcript, unnamedLabels: ["S1"])
        XCTAssertEqual(kept.count, 1)
    }

    func testAcceptsNameBackedByCalendarAttendees() {
        // "Pedro" never spoke his name, but the calendar invited him.
        let kept = NameSuggestionFilter.validSuggestions(
            [NameSuggestion(label: "S2", name: "Pedro", evidence: "context")],
            transcript: transcript, unnamedLabels: ["S1", "S2"],
            attendeeCandidates: ["Pedro Gómez", "Carolina Ruiz"])
        XCTAssertEqual(kept.count, 1, "first-name match against a full attendee name")
    }

    func testRejectsFabricatedNames() {
        let kept = NameSuggestionFilter.validSuggestions(
            [NameSuggestion(label: "S2", name: "John", evidence: "fabricated")],
            transcript: transcript, unnamedLabels: ["S1", "S2"],
            attendeeCandidates: ["Pedro Gómez"])
        XCTAssertTrue(kept.isEmpty)
    }

    func testRejectsLabelsAlreadyNamedOrUnknown() {
        let kept = NameSuggestionFilter.validSuggestions(
            [
                NameSuggestion(label: "Me", name: "Carolina", evidence: "x"),
                NameSuggestion(label: "S9", name: "Carolina", evidence: "x"),
            ],
            transcript: transcript, unnamedLabels: ["S1"])
        XCTAssertTrue(kept.isEmpty)
    }
}

// MARK: - Real-model integrations (gated)

final class VoiceIdentityIntegrationTests: XCTestCase {
    /// Enrolls a voice from a solo clip, then diarizes a two-voice
    /// conversation: the enrolled voice's turns must come back as "Me".
    /// Needs PORTAVOZ_MODEL_TESTS=1, the diarization model installed,
    /// PORTAVOZ_TEST_ENROLL_WAV (solo clip) and
    /// PORTAVOZ_TEST_CONVERSATION_WAV (same voice + another).
    func testEnrolledVoiceComesBackAsMe() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_MODEL_TESTS"] == "1",
            "set PORTAVOZ_MODEL_TESTS=1 to run")
        guard
            let enrollPath = ProcessInfo.processInfo.environment["PORTAVOZ_TEST_ENROLL_WAV"],
            let conversationPath = ProcessInfo.processInfo.environment["PORTAVOZ_TEST_CONVERSATION_WAV"]
        else {
            throw XCTSkip("set PORTAVOZ_TEST_ENROLL_WAV and PORTAVOZ_TEST_CONVERSATION_WAV")
        }

        let modelStore = ModelStore()
        let descriptor = ModelCatalog.speakerDiarization
        let report = await modelStore.verify(descriptor)
        try XCTSkipUnless(report.isComplete, "diarization model not installed")
        let directory = await modelStore.directory(for: descriptor)

        // Enroll from the solo clip.
        let enroller = try PyannoteDiarizer.load(fromVerifiedDirectory: directory)
        let voiceprint = try await enroller.extractVoiceprint(
            fromFile: URL(fileURLWithPath: enrollPath))
        XCTAssertEqual(voiceprint.embedding.count, 256)

        // Fresh diarizer with the voiceprint enrolled.
        let diarizer = try PyannoteDiarizer.load(
            fromVerifiedDirectory: directory, voiceprint: voiceprint)
        let turns = try await diarizer.diarizeFile(at: URL(fileURLWithPath: conversationPath))

        let labels = Set(turns.map(\.voiceLabel))
        XCTAssertTrue(labels.contains("Me"), "enrolled voice must be recognized: \(labels)")
        XCTAssertTrue(
            labels.contains { $0 != "Me" },
            "the other voice must stay a numbered speaker: \(labels)")

        // The enrolled voice should own a meaningful share of the turns.
        var meSeconds: TimeInterval = 0
        for turn in turns where turn.voiceLabel == "Me" {
            meSeconds += turn.endTime - turn.startTime
        }
        XCTAssertGreaterThan(meSeconds, 5, "expected several seconds of 'Me' speech")
    }

    /// FM proposes a name only when the transcript proves it.
    func testNamerFindsIntroducedNameAndSkipsUnproven() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_MODEL_TESTS"] == "1",
            "set PORTAVOZ_MODEL_TESTS=1 to run")
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw XCTSkip("Apple Intelligence unavailable: \(reason)")
        }

        let meeting = MeetingID()
        let me = PortavozCore.Speaker(meetingID: meeting, label: "Me", isMe: true)
        let s1 = PortavozCore.Speaker(meetingID: meeting, label: "S1")
        let s2 = PortavozCore.Speaker(meetingID: meeting, label: "S2")
        func line(_ speaker: PortavozCore.Speaker, _ text: String, _ at: TimeInterval)
            -> TranscriptSegment
        {
            TranscriptSegment(
                meetingID: meeting, speakerID: speaker.id,
                channel: speaker.isMe ? .microphone : .system,
                text: text, startTime: at, endTime: at + 3, isFinal: true)
        }
        let segments = [
            line(me, "Welcome everyone, let's start the sync.", 0),
            line(s1, "Hi all, Carolina here, I'll cover the backend update.", 4),
            line(me, "Thanks. After that we review the budget.", 8),
            line(s2, "The numbers look fine to me overall.", 12),
        ]

        let suggestions = try await SpeakerNamer().suggestNames(
            segments: segments, speakers: [me, s1, s2])

        XCTAssertTrue(
            suggestions.contains { $0.label == "S1" && $0.name.contains("Carolina") },
            "S1 introduced herself as Carolina: \(suggestions)")
        XCTAssertFalse(
            suggestions.contains { $0.label == "S2" },
            "S2 never said a name; nothing should be proposed: \(suggestions)")
    }
}
