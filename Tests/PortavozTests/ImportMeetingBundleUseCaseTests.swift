import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class ImportMeetingBundleUseCaseTests: XCTestCase {
    func testAttachmentValidationRejectsPathsUnknownChannelsAndUnsupportedFiles() throws {
        for invalidName in ["../system", "room", "system/backup"] {
            XCTAssertThrowsError(
                try ImportedMeetingBundleAttachment(
                    name: invalidName,
                    fileExtension: "m4a",
                    data: Data())) { error in
                        XCTAssertEqual(
                            error as? ImportMeetingBundleError,
                            .unsupportedAudioChannel(invalidName))
            }
        }

        for invalidExtension in ["mp3", "../m4a", "m4a/backup"] {
            XCTAssertThrowsError(
                try ImportedMeetingBundleAttachment(
                    name: "system",
                    fileExtension: invalidExtension,
                    data: Data())) { error in
                        XCTAssertEqual(
                            error as? ImportMeetingBundleError,
                            .unsupportedAudioExtension(invalidExtension))
            }
        }

        let normalized = try ImportedMeetingBundleAttachment(
            name: " Microphone ",
            fileExtension: " M4A ",
            data: Data([0x01]))
        XCTAssertEqual(normalized.channel, .microphone)
        XCTAssertEqual(normalized.fileExtension, "m4a")
    }

    func testDocumentRejectsDuplicateCanonicalAudioChannel() throws {
        let fixture = BundleImportFixture()
        let first = try fixture.attachment(name: "system")
        let duplicate = try fixture.attachment(name: " SYSTEM ")

        XCTAssertThrowsError(
            try fixture.document(attachments: [first, duplicate])) { error in
                XCTAssertEqual(
                    error as? ImportMeetingBundleError,
                    .duplicateAudioChannel(.system))
        }
    }

    func testTextOnlyImportClearsMachinePathAndInstallsCompleteAggregate() async throws {
        let fixture = BundleImportFixture()
        let dependencies = BundleImportDependencies(document: try fixture.document())

        let meetingID = try await fixture.useCase(dependencies).execute(
            ImportMeetingBundleRequest(sourceURL: fixture.sourceURL))

        let state = await dependencies.state()
        XCTAssertEqual(meetingID, fixture.meeting.id)
        XCTAssertEqual(state.events, [.read(fixture.sourceURL), .install])
        XCTAssertNil(state.snapshot?.meeting.audioDirectory)
        XCTAssertEqual(state.snapshot?.speakers.map(\.id), [fixture.speaker.id])
        XCTAssertEqual(state.snapshot?.segments.map(\.text), ["Ship the private beta."])
        XCTAssertEqual(state.snapshot?.summary?.markdown, "# Launch")
        XCTAssertEqual(state.snapshot?.contextItems.map(\.content), ["Keep rollout private"])
        XCTAssertEqual(state.snapshot?.companionCards.map(\.answer), ["Friday"])
        XCTAssertEqual(state.timestamp, fixture.now)
    }

    func testAudioImportStagesBeforeInstallAndPublishesOnlyCanonicalDirectory() async throws {
        let fixture = BundleImportFixture()
        let attachments = [
            try fixture.attachment(name: "system"),
            try fixture.attachment(name: "microphone", fileExtension: "wav")
        ]
        let dependencies = BundleImportDependencies(
            document: try fixture.document(attachments: attachments))

        _ = try await fixture.useCase(dependencies).execute(
            ImportMeetingBundleRequest(sourceURL: fixture.sourceURL))

        let state = await dependencies.state()
        XCTAssertEqual(state.events, [
            .read(fixture.sourceURL),
            .stage([.system, .microphone], fixture.meeting.id),
            .install
        ])
        XCTAssertEqual(
            state.snapshot?.meeting.audioDirectory,
            "Audio/\(fixture.meeting.id.rawValue.uuidString)")
    }

    func testDocumentOrStageFailureNeverAttemptsPersistence() async throws {
        let fixture = BundleImportFixture()
        for failure in [BundleImportFailure.document, .stage] {
            let dependencies = BundleImportDependencies(
                document: try fixture.document(attachments: [fixture.attachment()]),
                failures: [failure])

            do {
                _ = try await fixture.useCase(dependencies).execute(
                    ImportMeetingBundleRequest(sourceURL: fixture.sourceURL))
                XCTFail("\(failure) must fail the import")
            } catch {
                XCTAssertEqual(error as? BundleImportFailure, failure)
            }

            let state = await dependencies.state()
            XCTAssertFalse(state.events.contains(.install))
            XCTAssertNil(state.snapshot)
            XCTAssertFalse(state.events.contains { event in
                if case .discard = event { return true }
                return false
            })
        }
    }

    func testPersistenceFailureDiscardsStagedAudioWithoutMaskingOriginalError() async throws {
        let fixture = BundleImportFixture()
        let dependencies = BundleImportDependencies(
            document: try fixture.document(attachments: [fixture.attachment()]),
            failures: [.store, .discard])

        do {
            _ = try await fixture.useCase(dependencies).execute(
                ImportMeetingBundleRequest(sourceURL: fixture.sourceURL))
            XCTFail("store failure must reject the import")
        } catch {
            XCTAssertEqual(error as? BundleImportFailure, .store)
        }

        let state = await dependencies.state()
        XCTAssertEqual(state.events, [
            .read(fixture.sourceURL),
            .stage([.system], fixture.meeting.id),
            .install,
            .discard("Audio/\(fixture.meeting.id.rawValue.uuidString)")
        ])
        XCTAssertNil(state.snapshot)
    }

    func testRealStorePersistsEveryBundleChildAsOneVersionOneAggregate() async throws {
        let fixture = BundleImportFixture()
        let store = try MeetingStore.inMemory()
        let snapshot = fixture.snapshot()

        try await store.saveImportedMeetingBundle(snapshot, at: fixture.now)

        let detail = try await store.detail(fixture.meeting.id)
        let summary = try await store.summary(fixture.meeting.id)
        let notes = try await store.contextItems(for: fixture.meeting.id)
        let cards = try await store.companionCards(for: fixture.meeting.id)
        XCTAssertEqual(detail?.speakers.map(\.id), [fixture.speaker.id])
        XCTAssertEqual(detail?.segments.map(\.speakerID), [fixture.speaker.id])
        XCTAssertEqual(summary?.version, 1)
        XCTAssertEqual(summary?.draft.actionItems.first?.ownerSpeakerID, fixture.speaker.id)
        XCTAssertEqual(notes.map(\.content), ["Keep rollout private"])
        XCTAssertEqual(cards.map(\.question), ["When do we ship?"])
    }

    func testRealStoreRollsBackEveryRowWhenLastBundleChildFails() async throws {
        let fixture = BundleImportFixture()
        let store = try MeetingStore.inMemory()
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_import_card
                BEFORE INSERT ON companionCard
                BEGIN
                    SELECT RAISE(ABORT, 'injected final bundle child failure');
                END
                """)
        }

        do {
            try await store.saveImportedMeetingBundle(fixture.snapshot(), at: fixture.now)
            XCTFail("the final child failure must reject the complete aggregate")
        } catch {
            let meetings = try await store.meetings(includeDeleted: true)
            let summary = try await store.summary(fixture.meeting.id)
            let notes = try await store.contextItems(for: fixture.meeting.id)
            let cards = try await store.companionCards(for: fixture.meeting.id)
            XCTAssertTrue(meetings.isEmpty)
            XCTAssertNil(summary)
            XCTAssertTrue(notes.isEmpty)
            XCTAssertTrue(cards.isEmpty)
        }
    }

    func testRealStoreRejectsForeignSummaryAndNotesBeforeWriting() async throws {
        let fixture = BundleImportFixture()
        let store = try MeetingStore.inMemory()
        let foreignID = MeetingID()
        let foreignSummary = SummaryDraft(
            meetingID: foreignID,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "# Foreign",
            actionItems: [])
        let foreignNote = ContextItem(
            meetingID: foreignID,
            kind: .note,
            content: "Foreign",
            timestamp: 1)

        for snapshot in [
            fixture.snapshot(summary: foreignSummary),
            fixture.snapshot(contextItems: [foreignNote])
        ] {
            do {
                try await store.saveImportedMeetingBundle(snapshot, at: fixture.now)
                XCTFail("foreign children must be rejected")
            } catch let error as StorageError {
                guard case .invalidImportedMeeting = error else {
                    return XCTFail("unexpected storage error: \(error)")
                }
            }
        }

        let meetings = try await store.meetings(includeDeleted: true)
        XCTAssertTrue(meetings.isEmpty)
    }
}

private struct BundleImportFixture: Sendable {
    let sourceURL = URL(fileURLWithPath: "/tmp/meeting.portavoz")
    let now = Date(timeIntervalSince1970: 1_783_750_000)
    let meeting: Meeting
    let speaker: Speaker
    let segment: TranscriptSegment
    let summary: SummaryDraft
    let note: ContextItem
    let card: CompanionCard

    init() {
        let meeting = Meeting(
            id: MeetingID(rawValue: UUID(uuidString: "B2000000-0000-0000-0000-000000000001")!),
            title: "Private beta",
            startedAt: Date(timeIntervalSince1970: 1_783_749_000),
            endedAt: Date(timeIntervalSince1970: 1_783_749_600),
            language: "en",
            audioDirectory: "../../stale-machine-path")
        let speaker = Speaker(meetingID: meeting.id, label: "S1")
        self.meeting = meeting
        self.speaker = speaker
        self.segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "Ship the private beta.",
            language: "en",
            startTime: 1,
            endTime: 4,
            isFinal: true)
        self.summary = SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "# Launch",
            actionItems: [ActionItem(text: "Prepare rollout", ownerSpeakerID: speaker.id)])
        self.note = ContextItem(
            meetingID: meeting.id,
            kind: .note,
            content: "Keep rollout private",
            timestamp: 2)
        self.card = CompanionCard(
            question: "When do we ship?",
            answer: "Friday",
            kind: .context,
            source: "on-device",
            directed: true,
            askedAt: 3)
    }

    func attachment(
        name: String = "system",
        fileExtension: String = "m4a"
    ) throws -> ImportedMeetingBundleAttachment {
        try ImportedMeetingBundleAttachment(
            name: name,
            fileExtension: fileExtension,
            data: Data([0x01, 0x02]))
    }

    func document(
        attachments: [ImportedMeetingBundleAttachment] = []
    ) throws -> ImportedMeetingBundleDocument {
        try ImportedMeetingBundleDocument(
            meeting: meeting,
            speakers: [speaker],
            segments: [segment],
            summary: summary,
            contextItems: [note],
            companionCards: [card],
            attachments: attachments)
    }

    func snapshot(
        summary: SummaryDraft? = nil,
        contextItems: [ContextItem]? = nil
    ) -> ImportedMeetingBundleSnapshot {
        var storedMeeting = meeting
        storedMeeting.audioDirectory = nil
        return ImportedMeetingBundleSnapshot(
            meeting: storedMeeting,
            speakers: [speaker],
            segments: [segment],
            summary: summary ?? self.summary,
            contextItems: contextItems ?? [note],
            companionCards: [card])
    }

    func useCase(_ dependencies: BundleImportDependencies) -> ImportMeetingBundle {
        ImportMeetingBundle(
            documents: dependencies,
            files: dependencies,
            store: dependencies,
            now: { now })
    }
}

private enum BundleImportFailure: Error, Equatable, Hashable, Sendable {
    case document
    case stage
    case store
    case discard
}

private enum BundleImportEvent: Equatable, Sendable {
    case read(URL)
    case stage([AudioChannel], MeetingID)
    case install
    case discard(String)
}

private struct BundleImportState: Sendable {
    let events: [BundleImportEvent]
    let snapshot: ImportedMeetingBundleSnapshot?
    let timestamp: Date?
}

private actor BundleImportDependencies:
    ImportMeetingBundleDocuments,
    ImportMeetingBundleFiles,
    ImportMeetingBundleStore {
    private let document: ImportedMeetingBundleDocument
    private let failures: Set<BundleImportFailure>
    private var events: [BundleImportEvent] = []
    private var installedSnapshot: ImportedMeetingBundleSnapshot?
    private var installedAt: Date?

    init(
        document: ImportedMeetingBundleDocument,
        failures: Set<BundleImportFailure> = []
    ) {
        self.document = document
        self.failures = failures
    }

    func readRemappedBundle(from source: URL) throws -> ImportedMeetingBundleDocument {
        events.append(.read(source))
        if failures.contains(.document) { throw BundleImportFailure.document }
        return document
    }

    func stageBundleAudio(
        _ attachments: [ImportedMeetingBundleAttachment],
        meetingID: MeetingID
    ) throws -> ImportedMeetingBundleAudio {
        events.append(.stage(attachments.map(\.channel), meetingID))
        if failures.contains(.stage) { throw BundleImportFailure.stage }
        return ImportedMeetingBundleAudio(
            relativeDirectory: "Audio/\(meetingID.rawValue.uuidString)")
    }

    func discardBundleAudio(_ audio: ImportedMeetingBundleAudio) throws {
        events.append(.discard(audio.relativeDirectory))
        if failures.contains(.discard) { throw BundleImportFailure.discard }
    }

    func installImportedMeetingBundle(
        _ snapshot: ImportedMeetingBundleSnapshot,
        at timestamp: Date
    ) throws {
        events.append(.install)
        if failures.contains(.store) { throw BundleImportFailure.store }
        installedSnapshot = snapshot
        installedAt = timestamp
    }

    func state() -> BundleImportState {
        BundleImportState(
            events: events,
            snapshot: installedSnapshot,
            timestamp: installedAt)
    }
}
