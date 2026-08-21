import CryptoKit
import Foundation
import ModelStoreKit
import PortavozCore
import XCTest

@testable import DiarizationKit
@testable import IntelligenceKit

private func randomEncodedVoiceKey() -> String {
    SymmetricKey(size: .bits256).withUnsafeBytes {
        Data($0).base64EncodedString()
    }
}

private func encryptedVoiceFixture(
    plaintext: Data,
    encodedKey: String
) throws -> Data {
    let keyData = try XCTUnwrap(Data(base64Encoded: encodedKey))
    let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData))
    return try XCTUnwrap(box.combined)
}

// MARK: - Voiceprint storage (D8: encrypted, deletable, device-only)

final class VoiceprintStoreTests: XCTestCase {
    private var directory: URL!
    private var keyIdentifier: SecretIdentifier!
    private var secrets: TestSecretStorage!
    private var store: VoiceprintStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-voice-\(UUID().uuidString)")
        keyIdentifier = SecretIdentifier(
            rawValue: "app.portavoz.tests.voice.\(UUID().uuidString)")
        secrets = TestSecretStorage()
        store = VoiceprintStore(
            secrets: secrets,
            directory: directory,
            keyIdentifier: keyIdentifier)
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
        let lockURL = directory.appendingPathComponent("voiceprint.lock")
        XCTAssertEqual(try Data(contentsOf: lockURL), Data())
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
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
        XCTAssertNil(try secrets.value(for: keyIdentifier))
        XCTAssertNil(try store.load())
    }

    func testFileWithoutKeyFailsClosedAndPreservesCiphertext() throws {
        do {
            try store.save(Voiceprint(embedding: [1, 2, 3]))
        } catch {
            throw XCTSkip("keychain unavailable: \(error)")
        }
        let fileURL = directory.appendingPathComponent("voiceprint.enc")
        let ciphertext = try Data(contentsOf: fileURL)

        // Key vanishes (e.g. keychain reset): the encrypted file must stay
        // authoritative until the user explicitly deletes it.
        try secrets.delete(keyIdentifier)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(
                error as? VoiceprintStore.VoiceprintError,
                .missingKey)
        }
        XCTAssertThrowsError(try store.save(Voiceprint(embedding: [4, 5, 6]))) { error in
            XCTAssertEqual(
                error as? VoiceprintStore.VoiceprintError,
                .missingKey)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), ciphertext)
        XCTAssertNil(try secrets.value(for: keyIdentifier))

        try store.delete()
        try store.save(Voiceprint(embedding: [4, 5, 6]))
        XCTAssertEqual(try store.load()?.embedding, [4, 5, 6])
    }

    func testCorruptKeyOrCiphertextRejectsSaveUntilExplicitReset() throws {
        do {
            try store.save(Voiceprint(embedding: [1, 2, 3]))
        } catch {
            throw XCTSkip("keychain unavailable: \(error)")
        }
        let fileURL = directory.appendingPathComponent("voiceprint.enc")
        let ciphertext = try Data(contentsOf: fileURL)
        try secrets.set("not-a-valid-key", for: keyIdentifier)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(
                error as? VoiceprintStore.VoiceprintError,
                .corruptKey)
        }
        XCTAssertThrowsError(try store.save(Voiceprint(embedding: [4, 5, 6]))) { error in
            XCTAssertEqual(
                error as? VoiceprintStore.VoiceprintError,
                .corruptKey)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), ciphertext)
        XCTAssertEqual(try secrets.value(for: keyIdentifier), "not-a-valid-key")

        try store.delete()
        try store.save(Voiceprint(embedding: [4, 5, 6]))
        XCTAssertEqual(try store.load()?.embedding, [4, 5, 6])

        let replacementKey = try XCTUnwrap(secrets.value(for: keyIdentifier))
        let unreadable = Data("not-an-aes-gcm-box".utf8)
        try unreadable.write(to: fileURL, options: .atomic)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Voiceprint(embedding: [7, 8, 9])))
        XCTAssertEqual(try Data(contentsOf: fileURL), unreadable)
        XCTAssertEqual(try secrets.value(for: keyIdentifier), replacementKey)

        try store.delete()
        try store.save(Voiceprint(embedding: [7, 8, 9]))
        XCTAssertEqual(try store.load()?.embedding, [7, 8, 9])

        let authenticatedKey = try XCTUnwrap(secrets.value(for: keyIdentifier))
        let authenticatedCiphertext = try Data(contentsOf: fileURL)
        let wrongKey = randomEncodedVoiceKey()
        try secrets.set(wrongKey, for: keyIdentifier)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Voiceprint(embedding: [10, 11, 12])))
        XCTAssertEqual(try Data(contentsOf: fileURL), authenticatedCiphertext)
        XCTAssertEqual(try secrets.value(for: keyIdentifier), wrongKey)

        try secrets.set(authenticatedKey, for: keyIdentifier)
        let invalidJSON = try encryptedVoiceFixture(
            plaintext: Data("not-json".utf8),
            encodedKey: authenticatedKey)
        try invalidJSON.write(to: fileURL, options: .atomic)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Voiceprint(embedding: [10, 11, 12])))
        XCTAssertEqual(try Data(contentsOf: fileURL), invalidJSON)
        XCTAssertEqual(try secrets.value(for: keyIdentifier), authenticatedKey)

        try store.delete()
        try store.save(Voiceprint(embedding: [10, 11, 12]))
        XCTAssertEqual(try store.load()?.embedding, [10, 11, 12])
    }
}

// MARK: - Remembered voices of participants (D8: stricter than "Me")

final class VoiceGalleryTests: XCTestCase {
    private var directory: URL!
    private var keyIdentifier: SecretIdentifier!
    private var secrets: TestSecretStorage!
    private var gallery: VoiceGallery!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-gallery-\(UUID().uuidString)")
        keyIdentifier = SecretIdentifier(
            rawValue: "app.portavoz.tests.gallery.\(UUID().uuidString)")
        secrets = TestSecretStorage()
        gallery = VoiceGallery(
            secrets: secrets,
            directory: directory,
            keyIdentifier: keyIdentifier)
    }

    override func tearDownWithError() throws {
        try? gallery.deleteAll()
        try? FileManager.default.removeItem(at: directory)
    }

    func testRememberRoundTripIsEncryptedAtRest() throws {
        let voice = RememberedVoice(name: "Marta", embedding: (0..<256).map { Float($0) / 256 })
        do {
            try gallery.remember(voice)
        } catch {
            throw XCTSkip("keychain unavailable in this environment: \(error)")
        }

        let voices = try gallery.voices()
        XCTAssertEqual(voices.count, 1)
        XCTAssertEqual(voices[0].name, "Marta")
        XCTAssertEqual(voices[0].embedding, voice.embedding)

        let raw = try Data(contentsOf: directory.appendingPathComponent("voice-gallery.enc"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("Marta"))
        let lockURL = directory.appendingPathComponent("voice-gallery.lock")
        XCTAssertEqual(try Data(contentsOf: lockURL), Data())
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLockSymlinkFailsClosedBeforeIdentityMutation() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let targetURL = directory.appendingPathComponent("unrelated-lock-target")
        try Data().write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("voice-gallery.lock"),
            withDestinationURL: targetURL)

        XCTAssertThrowsError(try gallery.remember(
            RememberedVoice(name: "Marta", embedding: [1, 0, 0])))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("voice-gallery.enc").path))
        XCTAssertNil(try secrets.value(for: keyIdentifier))
        XCTAssertEqual(try Data(contentsOf: targetURL), Data())
    }

    func testReRememberingReplacesByNameCaseInsensitively() throws {
        do {
            try gallery.remember(RememberedVoice(name: "Marta", embedding: [1, 0, 0]))
        } catch {
            throw XCTSkip("keychain unavailable: \(error)")
        }
        try gallery.remember(RememberedVoice(name: "marta", embedding: [0, 1, 0]))

        let voices = try gallery.voices()
        XCTAssertEqual(voices.count, 1, "one embedding per person, refreshed")
        XCTAssertEqual(voices[0].embedding, [0, 1, 0])
    }

    func testRemoveLastVoiceDestroysFileAndKey() throws {
        let voice = RememberedVoice(name: "Ilarion", embedding: [1, 2, 3])
        do {
            try gallery.remember(voice)
        } catch {
            throw XCTSkip("keychain unavailable: \(error)")
        }

        try gallery.remove(id: voice.id)
        XCTAssertFalse(gallery.exists)
        XCTAssertNil(try secrets.value(for: keyIdentifier))
        XCTAssertTrue(try gallery.voices().isEmpty)
    }

    func testDeleteAllRemovesFileAndKeyInOneAction() throws {
        do {
            try gallery.remember(RememberedVoice(name: "Marta", embedding: [1]))
            try gallery.remember(RememberedVoice(name: "Ilarion", embedding: [2]))
        } catch {
            throw XCTSkip("keychain unavailable: \(error)")
        }

        try gallery.deleteAll()
        XCTAssertFalse(gallery.exists)
        XCTAssertNil(try secrets.value(for: keyIdentifier))
    }

    func testMissingKeyRejectsReadAndRememberWithoutReplacingCiphertext() throws {
        do {
            try gallery.remember(RememberedVoice(name: "Marta", embedding: [1, 0]))
        } catch {
            throw XCTSkip("keychain unavailable: \(error)")
        }
        let fileURL = directory.appendingPathComponent("voice-gallery.enc")
        let ciphertext = try Data(contentsOf: fileURL)
        try secrets.delete(keyIdentifier)

        XCTAssertThrowsError(try gallery.voices()) { error in
            XCTAssertEqual(
                error as? VoiceprintStore.VoiceprintError,
                .missingKey)
        }
        XCTAssertThrowsError(try gallery.remember(
            RememberedVoice(name: "Ilarion", embedding: [0, 1]))) { error in
                XCTAssertEqual(
                    error as? VoiceprintStore.VoiceprintError,
                    .missingKey)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), ciphertext)
        XCTAssertNil(try secrets.value(for: keyIdentifier))

        try gallery.deleteAll()
        let replacement = RememberedVoice(name: "Ilarion", embedding: [0, 1])
        try gallery.remember(replacement)
        XCTAssertEqual(try gallery.voices().map(\.name), ["Ilarion"])
    }

    func testUnreadableGalleryRejectsRememberWithoutReplacingTheFile() throws {
        do {
            try gallery.remember(RememberedVoice(name: "Marta", embedding: [1, 0]))
        } catch {
            throw XCTSkip("keychain unavailable: \(error)")
        }
        let fileURL = directory.appendingPathComponent("voice-gallery.enc")
        let ciphertext = try Data(contentsOf: fileURL)
        let encodedKey = try XCTUnwrap(secrets.value(for: keyIdentifier))
        let unreadable = Data("not-an-aes-gcm-box".utf8)
        try unreadable.write(to: fileURL, options: .atomic)

        XCTAssertThrowsError(try gallery.remember(
            RememberedVoice(name: "Ilarion", embedding: [0, 1])))
        XCTAssertEqual(try Data(contentsOf: fileURL), unreadable)
        XCTAssertEqual(try secrets.value(for: keyIdentifier), encodedKey)

        let invalidJSON = try encryptedVoiceFixture(
            plaintext: Data("not-json".utf8),
            encodedKey: encodedKey)
        try invalidJSON.write(to: fileURL, options: .atomic)
        XCTAssertThrowsError(try gallery.remember(
            RememberedVoice(name: "Ilarion", embedding: [0, 1])))
        XCTAssertEqual(try Data(contentsOf: fileURL), invalidJSON)
        XCTAssertEqual(try secrets.value(for: keyIdentifier), encodedKey)

        try ciphertext.write(to: fileURL, options: .atomic)
        let wrongKey = randomEncodedVoiceKey()
        try secrets.set(wrongKey, for: keyIdentifier)
        XCTAssertThrowsError(try gallery.remember(
            RememberedVoice(name: "Ilarion", embedding: [0, 1])))
        XCTAssertEqual(try Data(contentsOf: fileURL), ciphertext)
        XCTAssertEqual(try secrets.value(for: keyIdentifier), wrongKey)
    }

    func testUnreadableGalleryRejectsRemoveWithoutDeletingTheFileOrKey() throws {
        let voice = RememberedVoice(name: "Marta", embedding: [1, 0])
        do {
            try gallery.remember(voice)
        } catch {
            throw XCTSkip("keychain unavailable: \(error)")
        }
        let fileURL = directory.appendingPathComponent("voice-gallery.enc")
        let unreadable = Data("not-an-aes-gcm-box".utf8)
        try unreadable.write(to: fileURL, options: .atomic)

        XCTAssertThrowsError(try gallery.remove(id: voice.id))
        XCTAssertEqual(try Data(contentsOf: fileURL), unreadable)
        XCTAssertNotNil(try secrets.value(for: keyIdentifier))
    }
}

final class VoiceMatcherTests: XCTestCase {
    func testCosineDistanceBasics() {
        XCTAssertEqual(VoiceMatcher.cosineDistance([1, 0], [1, 0]), 0)
        XCTAssertEqual(VoiceMatcher.cosineDistance([1, 0], [0, 1]), 1)
        XCTAssertNil(VoiceMatcher.cosineDistance([1, 0], [1, 0, 0]), "dimension mismatch")
        XCTAssertNil(VoiceMatcher.cosineDistance([0, 0], [1, 0]), "zero vector never matches")
        XCTAssertNil(VoiceMatcher.cosineDistance([], []))
    }

    func testMatchesClosestVoiceWithinThreshold() {
        let gallery = [
            RememberedVoice(name: "Marta", embedding: [1, 0, 0]),
            RememberedVoice(name: "Ilarion", embedding: [0, 1, 0]),
        ]
        let matches = VoiceMatcher.matches(
            speakers: [("S1", [0.9, 0.1, 0]), ("S2", [0, 0, 1])],
            gallery: gallery)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].voiceLabel, "S1")
        XCTAssertEqual(matches[0].name, "Marta")
        XCTAssertLessThanOrEqual(matches[0].distance, VoiceMatcher.maxCosineDistance)
    }

    func testEachGalleryVoiceSuggestsAtMostOneSpeaker() {
        let gallery = [RememberedVoice(name: "Marta", embedding: [1, 0])]
        // Both speakers resemble Marta; only the closest may claim her.
        let matches = VoiceMatcher.matches(
            speakers: [("S1", [0.9, 0.1]), ("S2", [0.99, 0.01])],
            gallery: gallery)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].voiceLabel, "S2")
    }

    func testRespectsThresholdBoundary() {
        let gallery = [RememberedVoice(name: "Marta", embedding: [1, 0])]
        // Orthogonal voice (distance 1) is far past any sane threshold.
        let matches = VoiceMatcher.matches(speakers: [("S1", [0, 1])], gallery: gallery)
        XCTAssertTrue(matches.isEmpty)
    }

    func testDegenerateEmbeddingNeverMatches() {
        let gallery = [RememberedVoice(name: "Marta", embedding: [1, 0])]
        let matches = VoiceMatcher.matches(speakers: [("S1", [0, 0])], gallery: gallery)
        XCTAssertTrue(matches.isEmpty)
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
            [
                NameSuggestion(label: "S2", name: "John", evidence: "fabricated"),
                NameSuggestion(label: "S3", name: "Ana", evidence: "substring"),
            ],
            transcript: transcript + " The analysis is complete.",
            unnamedLabels: ["S1", "S2", "S3"],
            attendeeCandidates: ["Pedro Gómez"])
        XCTAssertTrue(kept.isEmpty)
    }

    func testNormalizesWhitespaceAndKeepsOnlyOneSuggestionPerLabel() {
        let kept = NameSuggestionFilter.validSuggestions(
            [
                NameSuggestion(label: " S1 ", name: " Carolina ", evidence: " first "),
                NameSuggestion(label: "S1", name: "Carolina", evidence: "duplicate"),
            ],
            transcript: transcript,
            unnamedLabels: ["S1"])

        XCTAssertEqual(kept, [
            NameSuggestion(label: "S1", name: "Carolina", evidence: "first"),
        ])
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
