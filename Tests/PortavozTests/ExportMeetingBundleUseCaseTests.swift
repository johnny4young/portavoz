import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class ExportMeetingBundleUseCaseTests: XCTestCase {
    func testAttachmentAdmitsOnlyCanonicalChannelsAndExtensions() throws {
        XCTAssertNil(ExportMeetingBundleAttachment(
            channel: .room,
            fileExtension: "m4a",
            data: Data()))
        XCTAssertNil(ExportMeetingBundleAttachment(
            channel: .system,
            fileExtension: "mp3",
            data: Data()))

        let attachment = try XCTUnwrap(ExportMeetingBundleAttachment(
            channel: .microphone,
            fileExtension: "M4A",
            data: Data([0x01])))
        XCTAssertEqual(attachment.channel, .microphone)
        XCTAssertEqual(attachment.fileExtension, "m4a")

        let fixture = BundleExportFixture()
        XCTAssertThrowsError(
            try ExportMeetingBundleDocument(
                content: fixture.content,
                attachments: [attachment, attachment])) { error in
                    XCTAssertEqual(
                        error as? ExportMeetingBundleError,
                        .duplicateAudioChannel(.microphone))
            }
    }

    func testTextOnlyExportPreservesAggregateAndClearsMachinePath() async throws {
        let fixture = BundleExportFixture()
        let dependencies = BundleExportDependencies(content: fixture.content)

        let data = try await fixture.useCase(
            store: dependencies,
            dependencies: dependencies
        ).execute(fixture.request(includeAudio: false))

        let state = await dependencies.state()
        XCTAssertEqual(data, fixture.encoded)
        XCTAssertEqual(state.events, [.load(fixture.meeting.id), .encode])
        XCTAssertNil(state.document?.meeting.audioDirectory)
        XCTAssertEqual(state.document?.meeting.title, fixture.meeting.title)
        XCTAssertEqual(state.document?.speakers.map(\.id), [fixture.speaker.id])
        XCTAssertEqual(state.document?.segments.map(\.text), ["Conservar español."])
        XCTAssertEqual(state.document?.summary?.markdown, "# Último")
        XCTAssertEqual(state.document?.contextItems.map(\.content), ["No traducir"])
        XCTAssertEqual(state.document?.companionCards.map(\.answer), ["Mañana"])
        XCTAssertTrue(state.document?.attachments.isEmpty == true)
    }

    func testAudioExportReadsCanonicalAttachmentsBeforeEncoding() async throws {
        let fixture = BundleExportFixture()
        let attachments = [
            try XCTUnwrap(ExportMeetingBundleAttachment(
                channel: .system,
                fileExtension: "m4a",
                data: Data([0x01]))),
            try XCTUnwrap(ExportMeetingBundleAttachment(
                channel: .microphone,
                fileExtension: "caf",
                data: Data([0x02])))
        ]
        let dependencies = BundleExportDependencies(
            content: fixture.content,
            attachments: attachments)

        _ = try await fixture.useCase(
            store: dependencies,
            dependencies: dependencies
        ).execute(fixture.request(includeAudio: true))

        let state = await dependencies.state()
        XCTAssertEqual(
            state.events,
            [.load(fixture.meeting.id), .readAudio("Audio/export"), .encode])
        XCTAssertEqual(state.document?.attachments, attachments)
        XCTAssertNil(state.document?.meeting.audioDirectory)
    }

    func testAudioReadIsSkippedWithoutOptInOrStoredDirectory() async throws {
        let fixture = BundleExportFixture()
        let withoutOptIn = BundleExportDependencies(content: fixture.content)
        _ = try await fixture.useCase(
            store: withoutOptIn,
            dependencies: withoutOptIn
        ).execute(fixture.request(includeAudio: false))
        let withoutOptInEvents = await withoutOptIn.events()
        XCTAssertEqual(withoutOptInEvents, [.load(fixture.meeting.id), .encode])

        var meeting = fixture.meeting
        meeting.audioDirectory = nil
        let withoutDirectory = BundleExportDependencies(
            content: fixture.content(meeting: meeting))
        _ = try await fixture.useCase(
            store: withoutDirectory,
            dependencies: withoutDirectory
        ).execute(fixture.request(includeAudio: true))
        let withoutDirectoryEvents = await withoutDirectory.events()
        XCTAssertEqual(withoutDirectoryEvents, [.load(fixture.meeting.id), .encode])
    }

    func testMissingMeetingStopsBeforeFilesAndDocument() async {
        let fixture = BundleExportFixture()
        let dependencies = BundleExportDependencies(content: nil)

        do {
            _ = try await fixture.useCase(
                store: dependencies,
                dependencies: dependencies
            ).execute(fixture.request(includeAudio: true))
            XCTFail("a missing live meeting must fail")
        } catch {
            XCTAssertEqual(
                error as? ExportMeetingBundleError,
                .meetingNotFound(fixture.meeting.id))
        }
        let events = await dependencies.events()
        XCTAssertEqual(events, [.load(fixture.meeting.id)])
    }

    func testStoreAndDocumentFailuresPropagateAtTheirBoundaries() async {
        let fixture = BundleExportFixture()
        for failure in [BundleExportFailure.store, .document] {
            let dependencies = BundleExportDependencies(
                content: fixture.content,
                failures: [failure])
            do {
                _ = try await fixture.useCase(
                    store: dependencies,
                    dependencies: dependencies
                ).execute(fixture.request(includeAudio: true))
                XCTFail("\(failure) must propagate")
            } catch {
                XCTAssertEqual(error as? BundleExportFailure, failure)
            }
            let events = await dependencies.events()
            if failure == .store {
                XCTAssertEqual(events, [.load(fixture.meeting.id)])
            } else {
                XCTAssertEqual(
                    events,
                    [.load(fixture.meeting.id), .readAudio("Audio/export"), .encode])
            }
        }
    }

    func testRealStoreExportsNewestCrossRecipeSnapshotAndEveryLiveChild() async throws {
        let fixture = BundleExportFixture()
        let store = try MeetingStore.inMemory()
        try await store.saveImportedMeetingBundle(
            ImportedMeetingBundleSnapshot(
                meeting: fixture.meeting,
                speakers: [fixture.speaker],
                segments: [fixture.segment],
                summary: fixture.summary(markdown: "# Older", recipeID: Recipe.general.id),
                contextItems: [fixture.note],
                companionCards: [fixture.card]),
            at: Date(timeIntervalSince1970: 1_000))
        _ = try await store.saveSummary(
            fixture.summary(markdown: "# Newest", recipeID: Recipe.standup.id))
        let newestValue = try await store.summary(
            fixture.meeting.id,
            recipeID: Recipe.standup.id)
        let newest = try XCTUnwrap(newestValue)
        let claim = try XCTUnwrap(newest.draft.claims.first)
        try await store.setSummaryClaimFeedback(
            SummaryClaimFeedback.correction("Publicar después de QA."),
            for: claim.id,
            meetingID: fixture.meeting.id)
        let dependencies = BundleExportDependencies(content: nil)

        _ = try await fixture.useCase(
            store: store,
            dependencies: dependencies
        ).execute(fixture.request(includeAudio: false))

        let document = await dependencies.document()
        XCTAssertEqual(document?.summary?.markdown, "# Newest")
        XCTAssertEqual(document?.summary?.recipeID, Recipe.standup.id)
        XCTAssertEqual(
            document?.summary?.claims.first?.feedback?.correctionText,
            "Publicar después de QA.")
        XCTAssertEqual(document?.speakers.map(\.id), [fixture.speaker.id])
        XCTAssertEqual(document?.segments.map(\.id), [fixture.segment.id])
        XCTAssertEqual(document?.contextItems.map(\.id), [fixture.note.id])
        XCTAssertEqual(document?.companionCards.map(\.id), [fixture.card.id])
        XCTAssertNil(document?.meeting.audioDirectory)

        try await store.delete(fixture.meeting.id)
        do {
            _ = try await fixture.useCase(
                store: store,
                dependencies: dependencies
            ).execute(fixture.request(includeAudio: false))
            XCTFail("tombstoned meetings must not export")
        } catch {
            XCTAssertEqual(
                error as? ExportMeetingBundleError,
                .meetingNotFound(fixture.meeting.id))
        }
    }

    func testCorruptOptionalRowsDegradeWithoutLosingCoreExport() async throws {
        let fixture = BundleExportFixture()
        let store = try MeetingStore.inMemory()
        try await store.saveImportedMeetingBundle(
            ImportedMeetingBundleSnapshot(
                meeting: fixture.meeting,
                speakers: [fixture.speaker],
                segments: [fixture.segment],
                summary: fixture.summary,
                contextItems: [fixture.note],
                companionCards: [fixture.card]),
            at: Date())
        try await store.database.write { db in
            try db.execute(
                sql: "UPDATE contextItem SET kind = 'invalid' WHERE id = ?",
                arguments: [fixture.note.id.uuidString])
        }
        let dependencies = BundleExportDependencies(content: nil)

        _ = try await fixture.useCase(
            store: store,
            dependencies: dependencies
        ).execute(fixture.request(includeAudio: false))

        let document = await dependencies.document()
        XCTAssertEqual(document?.segments.map(\.id), [fixture.segment.id])
        XCTAssertEqual(document?.summary?.markdown, "# Último")
        XCTAssertTrue(document?.contextItems.isEmpty == true)
        XCTAssertEqual(document?.companionCards.map(\.id), [fixture.card.id])
    }
}

private struct BundleExportFixture {
    let meeting: Meeting
    let speaker: Speaker
    let segment: TranscriptSegment
    let summary: SummaryDraft
    let note: ContextItem
    let card: CompanionCard
    let encoded = Data("encoded-portavoz".utf8)

    init() {
        let meeting = Meeting(
            title: "Reunión bilingüe",
            startedAt: Date(timeIntervalSince1970: 1_789_000_000),
            language: nil,
            audioDirectory: "Audio/export")
        let speaker = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Ana")
        self.meeting = meeting
        self.speaker = speaker
        self.segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "Conservar español.",
            language: "es",
            startTime: 1,
            endTime: 3,
            isFinal: true)
        self.summary = SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "# Último",
            actionItems: [ActionItem(text: "Publicar", ownerSpeakerID: speaker.id)],
            claims: [SummaryClaim(
                kind: .overview,
                evidenceSegmentIDs: [self.segment.id])])
        self.note = ContextItem(
            meetingID: meeting.id,
            kind: .note,
            content: "No traducir",
            timestamp: 4)
        self.card = CompanionCard(
            question: "¿Cuándo?",
            answer: "Mañana",
            kind: .context,
            source: "on-device",
            askedAt: 5)
    }

    var content: ExportMeetingBundleContent {
        content(meeting: meeting)
    }

    func content(meeting: Meeting) -> ExportMeetingBundleContent {
        ExportMeetingBundleContent(
            meeting: meeting,
            speakers: [speaker],
            segments: [segment],
            summary: summary,
            contextItems: [note],
            companionCards: [card])
    }

    func summary(markdown: String, recipeID: String) -> SummaryDraft {
        SummaryDraft(
            meetingID: meeting.id,
            recipeID: recipeID,
            language: "es",
            markdown: markdown,
            actionItems: [ActionItem(text: "Publicar", ownerSpeakerID: speaker.id)],
            claims: [SummaryClaim(
                kind: .overview,
                evidenceSegmentIDs: [segment.id])])
    }

    func request(includeAudio: Bool) -> ExportMeetingBundleRequest {
        ExportMeetingBundleRequest(
            meetingID: meeting.id,
            includeAudio: includeAudio)
    }

    func useCase(
        store: any ExportMeetingBundleStore,
        dependencies: BundleExportDependencies
    ) -> ExportMeetingBundle {
        ExportMeetingBundle(
            store: store,
            files: dependencies,
            documents: dependencies)
    }
}

private enum BundleExportEvent: Equatable {
    case load(MeetingID)
    case readAudio(String)
    case encode
}

private enum BundleExportFailure: Error, Equatable {
    case store
    case document
}

private struct BundleExportState: Sendable {
    let events: [BundleExportEvent]
    let document: ExportMeetingBundleDocument?
}

private actor BundleExportDependencies:
    ExportMeetingBundleStore,
    ExportMeetingBundleFiles,
    ExportMeetingBundleDocuments {
    private let content: ExportMeetingBundleContent?
    private let attachments: [ExportMeetingBundleAttachment]
    private let failures: Set<BundleExportFailure>
    private var recordedEvents: [BundleExportEvent] = []
    private var recordedDocument: ExportMeetingBundleDocument?

    init(
        content: ExportMeetingBundleContent?,
        attachments: [ExportMeetingBundleAttachment] = [],
        failures: Set<BundleExportFailure> = []
    ) {
        self.content = content
        self.attachments = attachments
        self.failures = failures
    }

    func meetingBundleExportContent(
        for meetingID: MeetingID
    ) throws -> ExportMeetingBundleContent? {
        recordedEvents.append(.load(meetingID))
        if failures.contains(.store) { throw BundleExportFailure.store }
        return content
    }

    func readBundleAudio(
        from relativeDirectory: String
    ) -> [ExportMeetingBundleAttachment] {
        recordedEvents.append(.readAudio(relativeDirectory))
        return attachments
    }

    func encodeMeetingBundle(
        _ document: ExportMeetingBundleDocument
    ) throws -> Data {
        recordedEvents.append(.encode)
        recordedDocument = document
        if failures.contains(.document) { throw BundleExportFailure.document }
        return Data("encoded-portavoz".utf8)
    }

    func state() -> BundleExportState {
        BundleExportState(events: recordedEvents, document: recordedDocument)
    }

    func events() -> [BundleExportEvent] { recordedEvents }
    func document() -> ExportMeetingBundleDocument? { recordedDocument }
}
