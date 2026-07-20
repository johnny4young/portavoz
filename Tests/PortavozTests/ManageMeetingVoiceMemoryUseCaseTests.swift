import ApplicationKit
import DiarizationKit
import Foundation
import PortavozCore
import XCTest

final class ManageMeetingVoiceMemoryUseCaseTests: XCTestCase {
    func testSuggestionsMatchOnlyUnnamedRemoteSpeakers() async throws {
        let fixture = MeetingVoiceFixture()
        let memory = MeetingVoiceMemoryFake(voices: [
            RememberedVoice(name: "Ana", embedding: [1, 0])
        ])
        let extractor = MeetingVoiceExtractorFake(prints: [
            "S1": Voiceprint(embedding: [1, 0]),
            "S2": Voiceprint(embedding: [1, 0])
        ])
        let useCase = fixture.useCase(memory: memory, extractor: extractor)

        let result = try await useCase.execute(.init(
            action: .suggestions(meetingID: fixture.meetingID)))

        XCTAssertEqual(result, .suggestions([
            MeetingVoiceSuggestion(speakerLabel: "S1", name: "Ana", distance: 0)
        ]))
        let requestedLabels = await extractor.requestedLabels
        XCTAssertEqual(requestedLabels, [["S1"]])
    }

    func testSuggestionsDegradeWithoutGalleryOrExtraction() async throws {
        let fixture = MeetingVoiceFixture()
        let extractor = MeetingVoiceExtractorFake(prints: [:])
        let useCase = fixture.useCase(
            memory: MeetingVoiceMemoryFake(voices: []),
            extractor: extractor)

        let result = try await useCase.execute(.init(
            action: .suggestions(meetingID: fixture.meetingID)))

        XCTAssertEqual(result, .suggestions([]))
        let requestedLabels = await extractor.requestedLabels
        XCTAssertTrue(requestedLabels.isEmpty)
    }

    func testCanRememberIsCaseInsensitiveAndReadFailureKeepsOfferAvailable() async throws {
        let fixture = MeetingVoiceFixture(remoteName: "Ana")
        let extractor = MeetingVoiceExtractorFake(prints: [:])
        let existing = fixture.useCase(
            memory: MeetingVoiceMemoryFake(voices: [
                RememberedVoice(name: "Ana", embedding: [1])
            ]),
            extractor: extractor)
        let unavailable = fixture.useCase(
            memory: MeetingVoiceMemoryFake(voices: [], failReads: true),
            extractor: extractor)

        let duplicate = try await existing.execute(.init(
            action: .canRemember(name: "ana")))
        let retryable = try await unavailable.execute(.init(
            action: .canRemember(name: "Marta")))

        XCTAssertEqual(duplicate, .canRemember(false))
        XCTAssertEqual(retryable, .canRemember(true))
    }

    func testRememberRequiresExplicitNamedSpeakerAndPersistsOneEmbedding() async throws {
        let fixture = MeetingVoiceFixture(remoteName: "Ana")
        let memory = MeetingVoiceMemoryFake(voices: [])
        let extractor = MeetingVoiceExtractorFake(prints: [
            "S1": Voiceprint(embedding: [0.25, 0.75])
        ])
        let useCase = fixture.useCase(memory: memory, extractor: extractor)

        let result = try await useCase.execute(.init(action: .remember(
            meetingID: fixture.meetingID,
            speakerID: fixture.remoteSpeaker.id)))

        XCTAssertEqual(result, .remembered)
        let remembered = await memory.remembered
        XCTAssertEqual(remembered.map(\.name), ["Ana"])
        XCTAssertEqual(remembered.map(\.embedding), [[0.25, 0.75]])
    }

    func testRememberReportsInsufficientAudioWithoutWriting() async throws {
        let fixture = MeetingVoiceFixture(remoteName: "Ana")
        let memory = MeetingVoiceMemoryFake(voices: [])
        let useCase = fixture.useCase(
            memory: memory,
            extractor: MeetingVoiceExtractorFake(prints: [:]))

        let result = try await useCase.execute(.init(action: .remember(
            meetingID: fixture.meetingID,
            speakerID: fixture.remoteSpeaker.id)))

        XCTAssertEqual(result, .insufficientAudio)
        let remembered = await memory.remembered
        XCTAssertTrue(remembered.isEmpty)
    }

    func testRememberRejectsMeAndUnnamedSpeakers() async {
        let fixture = MeetingVoiceFixture()
        let useCase = fixture.useCase(
            memory: MeetingVoiceMemoryFake(voices: []),
            extractor: MeetingVoiceExtractorFake(prints: [:]))

        for speakerID in [fixture.remoteSpeaker.id, fixture.meSpeaker.id] {
            do {
                _ = try await useCase.execute(.init(action: .remember(
                    meetingID: fixture.meetingID,
                    speakerID: speakerID)))
                XCTFail("remembering must require a named non-user speaker")
            } catch let error as ManageMeetingVoiceMemoryError {
                XCTAssertEqual(error, .namedSpeakerNotFound)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRememberSurfacesEncryptedGalleryWriteFailure() async {
        let fixture = MeetingVoiceFixture(remoteName: "Ana")
        let memory = MeetingVoiceMemoryFake(voices: [], failWrites: true)
        let useCase = fixture.useCase(
            memory: memory,
            extractor: MeetingVoiceExtractorFake(prints: [
                "S1": Voiceprint(embedding: [1, 0])
            ]))

        do {
            _ = try await useCase.execute(.init(action: .remember(
                meetingID: fixture.meetingID,
                speakerID: fixture.remoteSpeaker.id)))
            XCTFail("an encrypted gallery write failure must remain visible")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteUnknown)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let remembered = await memory.remembered
        XCTAssertTrue(remembered.isEmpty)
    }
}

private struct MeetingVoiceFixture {
    let meetingID = MeetingID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000000511")!)
    let remoteSpeaker: Speaker
    let meSpeaker: Speaker
    let detail: MeetingLibraryDetail

    init(remoteName: String? = nil) {
        remoteSpeaker = Speaker(
            meetingID: meetingID,
            label: "S1",
            displayName: remoteName)
        let namedRemote = Speaker(
            meetingID: meetingID,
            label: "S2",
            displayName: "Marta")
        meSpeaker = Speaker(
            meetingID: meetingID,
            label: "Me",
            displayName: "Me",
            isMe: true)
        detail = MeetingLibraryDetail(
            meeting: Meeting(
                id: meetingID,
                title: "Voice memory",
                startedAt: Date(timeIntervalSince1970: 10)),
            speakers: [
                remoteSpeaker,
                namedRemote,
                meSpeaker
            ],
            segments: [],
            summary: nil,
            summaryVersion: nil)
    }

    func useCase(
        memory: MeetingVoiceMemoryFake,
        extractor: MeetingVoiceExtractorFake
    ) -> ManageMeetingVoiceMemory {
        ManageMeetingVoiceMemory(
            library: QueryMeetingLibrary(reader: MeetingVoiceReaderFake(detail: detail)),
            memory: memory,
            extractor: extractor)
    }
}

private actor MeetingVoiceReaderFake: MeetingLibraryQueryReading {
    let detail: MeetingLibraryDetail?
    init(detail: MeetingLibraryDetail?) { self.detail = detail }

    func meetingLibraryMeetings(limit: Int?) -> [Meeting] {
        _ = limit
        return []
    }

    func meetingLibraryDetail(_ id: MeetingID) -> MeetingLibraryDetail? {
        _ = id
        return detail
    }

    func meetingLibrarySearch(_ query: String, limit: Int) -> [LibrarySearchHit] {
        _ = query
        _ = limit
        return []
    }

    func meetingLibraryOpenItems(limit: Int) -> [LibraryOpenItem] {
        _ = limit
        return []
    }
}

private actor MeetingVoiceMemoryFake: RememberedVoiceMemory {
    let voices: [RememberedVoice]
    let failReads: Bool
    let failWrites: Bool
    private(set) var remembered: [RememberedVoice] = []

    init(
        voices: [RememberedVoice],
        failReads: Bool = false,
        failWrites: Bool = false
    ) {
        self.voices = voices
        self.failReads = failReads
        self.failWrites = failWrites
    }

    func rememberedVoices() throws -> [RememberedVoice] {
        if failReads { throw CocoaError(.fileReadUnknown) }
        return voices
    }

    func rememberVoice(_ voice: RememberedVoice) throws {
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        remembered.append(voice)
    }
}

private actor MeetingVoiceExtractorFake: MeetingVoiceprintExtracting {
    let prints: [String: Voiceprint]
    private(set) var requestedLabels: [[String]] = []

    init(prints: [String: Voiceprint]) {
        self.prints = prints
    }

    func extractVoiceprints(
        from detail: MeetingLibraryDetail,
        speakerLabels: [String]
    ) -> [String: Voiceprint] {
        _ = detail
        requestedLabels.append(speakerLabels)
        return prints.filter { speakerLabels.contains($0.key) }
    }
}
